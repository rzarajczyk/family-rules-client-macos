import AppKit
import Foundation
import SQLite3

enum LifecycleShutdownAction: Equatable {
    case disable
    case uninstall
}

enum ManualRefreshOutcome: Equatable {
    case success(deviceState: String, extra: String?, serverCommands: [ServerCommandPayload])
    case unreachable
    case error(String)
}

@MainActor
final class SyncController: ObservableObject {
    @Published private(set) var syncStatus = "Idle"
    @Published private(set) var lastClientInfoDescription = "Never"
    @Published private(set) var lastReportDescription = "Never"
    @Published private(set) var lastDeviceState = "Unknown"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var lastCommandErrorMessage: String?
    @Published private(set) var recentLogLines: [String] = []
    @Published private(set) var blockedAppIdentifiers: Set<String> = []
    @Published private(set) var blockedAppNames: [String: String] = [:]
    @Published private(set) var pendingCommandCount = 0
    @Published private(set) var lastCommandDescription = "None"
    @Published private(set) var mediaPlayingApps: Set<String> = []

    private let activityMonitor: any ActivityMonitorProtocol
    private let syncClient: any ServerSyncClientProtocol
    private let lifecycleController: (any LifecycleControlling)?
    private let playbackBlocker: any PlaybackBlockingProtocol
    private let playbackProbe: any MediaRemotePlaybackProbeProtocol
    private let commandStore: any ServerCommandStoreProtocol
    private let diagnosticsLogStore: any DiagnosticsLogStoreProtocol
    private let appVersionProvider: () -> String
    private let timezoneProvider: () -> Int
    private let clientInfoIntervalSeconds: Int
    private let reportIntervalSeconds: Int
    private let automaticLoops: Bool
    private let sleep: @Sendable (Int) async throws -> Void

    private var registration: RegistrationRecord?
    private var clientInfoTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var mediaPlayingTask: Task<Void, Never>?
    private var isSendingClientInfo = false
    private var isSendingReport = false
    private var isFetchingBlockedApps = false
    private var isFetchingBlockedPlaybackApps = false
    private var isProcessingCommands = false
    private var isLifecycleShutdownInProgress = false

    var onLifecycleShutdown: ((LifecycleShutdownAction) -> Void)?

    init(
        activityMonitor: any ActivityMonitorProtocol,
        syncClient: any ServerSyncClientProtocol = ServerSyncClient(),
        lifecycleController: (any LifecycleControlling)? = nil,
        playbackBlocker: any PlaybackBlockingProtocol = PlaybackBlocker(),
        playbackProbe: any MediaRemotePlaybackProbeProtocol = MediaRemotePlaybackProbe(),
        commandStore: any ServerCommandStoreProtocol = SQLiteServerCommandStore(),
        diagnosticsLogStore: any DiagnosticsLogStoreProtocol = DiagnosticsLogStore(),
        appVersionProvider: @escaping () -> String = SyncController.defaultAppVersion,
        timezoneProvider: @escaping () -> Int = { TimeZone.current.secondsFromGMT() },
        clientInfoIntervalSeconds: Int = 600,
        reportIntervalSeconds: Int = 30,
        automaticLoops: Bool = true,
        sleep: @escaping @Sendable (Int) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.activityMonitor = activityMonitor
        self.syncClient = syncClient
        self.lifecycleController = lifecycleController
        self.playbackBlocker = playbackBlocker
        self.playbackProbe = playbackProbe
        self.commandStore = commandStore
        self.diagnosticsLogStore = diagnosticsLogStore
        self.appVersionProvider = appVersionProvider
        self.timezoneProvider = timezoneProvider
        self.clientInfoIntervalSeconds = clientInfoIntervalSeconds
        self.reportIntervalSeconds = reportIntervalSeconds
        self.automaticLoops = automaticLoops
        self.sleep = sleep
        // I/O deferred to start() to avoid blocking the main thread during init.
    }

    func start(registration: RegistrationRecord) async {
        stop()

        self.registration = registration
        lifecycleController?.start(registration: registration)
        lifecycleController?.onRestrictedAppBlockingActivated = { [weak self] in
            guard let self else { return }
            Task { await self.handleRestrictedAppBlockingActivated() }
        }
        syncStatus = "Starting"
        // Load persisted diagnostics state now that we are starting (not in init).
        refreshDiagnosticsState()
        recordLog("Starting sync for \(registration.instanceName)")
        // The closure is `@MainActor` because `ActivityMonitorProtocol` is `@MainActor`-isolated,
        // so `self` is always accessed on the main actor — no extra hop needed.
        activityMonitor.onKnownAppsChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.sendClientInfo(reason: "app inventory changed")
            }
        }

        await sendClientInfo(reason: "startup")
        await sendReportIfEligible(reason: "startup")

        guard automaticLoops else { return }

        clientInfoTask = Task { [weak self] in
            guard let self else { return }
            await self.runClientInfoLoop()
        }

        reportTask = Task { [weak self] in
            guard let self else { return }
            await self.runReportLoop()
        }

        mediaPlayingTask = Task { [weak self] in
            guard let self else { return }
            await self.runMediaPlayingLoop()
        }
    }

    func stop() {
        clientInfoTask?.cancel()
        reportTask?.cancel()
        mediaPlayingTask?.cancel()
        clientInfoTask = nil
        reportTask = nil
        mediaPlayingTask = nil
        registration = nil
        activityMonitor.onKnownAppsChanged = nil
        lifecycleController?.onRestrictedAppBlockingActivated = nil
        lifecycleController?.stop()
        blockedAppIdentifiers = []
        blockedAppNames = [:]
        Task {
            await playbackBlocker.clear()
        }

        if syncStatus != "Idle" {
            syncStatus = "Idle"
        }
    }

    private func runClientInfoLoop() async {
        while !Task.isCancelled {
            do {
                try await sleep(clientInfoIntervalSeconds)
            } catch {
                return
            }

            await sendClientInfo(reason: "periodic")
        }
    }

    private func runReportLoop() async {
        while !Task.isCancelled {
            do {
                try await sleep(reportIntervalSeconds)
            } catch {
                return
            }

            await sendReportIfEligible(reason: "periodic")
        }
    }

    func sendClientInfo(reason: String) async {
        guard let registration, !isSendingClientInfo else { return }

        isSendingClientInfo = true
        defer { isSendingClientInfo = false }

        let snapshot = activityMonitor.snapshot()
        let payload = ClientInfoPayload(
            version: appVersionProvider(),
            availableStates: [
                AvailableStatePayload(
                    deviceState: "ACTIVE",
                    title: "Active",
                    icon: nil,
                    description: nil,
                    arguments: nil
                ),
                AvailableStatePayload(
                    deviceState: "LOCK_SCREEN",
                    title: "Lock Screen",
                    icon: nil,
                    description: nil,
                    arguments: nil
                ),
                AvailableStatePayload(
                    deviceState: "LOCK_SCREEN_WITH_TIMEOUT",
                    title: "Lock Screen With Countdown",
                    icon: nil,
                    description: nil,
                    arguments: ["seconds"]
                ),
                AvailableStatePayload(
                    deviceState: "LOGOUT",
                    title: "Logout",
                    icon: nil,
                    description: nil,
                    arguments: nil
                ),
                AvailableStatePayload(
                    deviceState: "LOGOUT_WITH_TIMEOUT",
                    title: "Logout With Countdown",
                    icon: nil,
                    description: nil,
                    arguments: ["seconds"]
                ),
                AvailableStatePayload(
                    deviceState: "BLOCK_RESTRICTED_APPS",
                    title: "Block Restricted Apps",
                    icon: nil,
                    description: nil,
                    arguments: nil
                ),
                AvailableStatePayload(
                    deviceState: "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT",
                    title: "Block Restricted Apps With Countdown",
                    icon: nil,
                    description: nil,
                    arguments: ["seconds"]
                ),
            ],
            timezoneOffsetSeconds: timezoneProvider(),
            reportIntervalSeconds: reportIntervalSeconds,
            knownApps: snapshot.knownApps.mapValues { KnownAppPayload(appName: $0.name, iconBase64Png: iconBase64Png(for: $0.identifier)) },
            capabilities: Self.advertisedCapabilities()
        )

        do {
            try await syncClient.sendClientInfo(payload, registration: registration)
            lastClientInfoDescription = "\(DiagnosticsLogFormatting.timestamp()) via \(reason)"
            lastErrorMessage = nil
            syncStatus = syncStatus == "Paused" ? "Paused" : "Healthy"
            recordLog("Sent client-info (\(reason)) with \(payload.knownApps.count) known apps")
            await processPendingCommands(reason: "client-info \(reason)")
        } catch {
            syncStatus = "Error"
            lastErrorMessage = error.localizedDescription
            DiagnosticsLogger.record(error: error, context: "Client-info request failed")
            recordLog("Client-info failed (\(reason)): \(error.localizedDescription)")
        }
    }

    func sendReportIfEligible(reason: String) async {
        guard let registration, !isSendingReport else { return }

        let snapshot = activityMonitor.snapshot()
        guard snapshot.isEligibleForReporting else {
            syncStatus = "Paused"
            return
        }

        await sendReport(reason: reason, snapshot: snapshot, registration: registration)
    }

    func manualRefresh() async -> ManualRefreshOutcome {
        guard let registration else {
            return .error("This Mac is not registered.")
        }

        guard !isSendingReport else {
            return .error("A report is already in progress.")
        }

        let snapshot = activityMonitor.snapshot()
        return await sendReport(
            reason: "manual refresh",
            snapshot: snapshot,
            registration: registration,
            force: true
        ) ?? .error("A report is already in progress.")
    }

    @discardableResult
    private func sendReport(
        reason: String,
        snapshot: UsageSnapshot,
        registration: RegistrationRecord,
        force: Bool = false
    ) async -> ManualRefreshOutcome? {
        guard !isSendingReport else {
            return force ? .error("A report is already in progress.") : nil
        }

        isSendingReport = true
        defer { isSendingReport = false }

        do {
            let mediaPlayingApps = await currentMediaPlayingApps()
            self.mediaPlayingApps = mediaPlayingApps
            // Ensure media-playing apps appear in the applications dict even with 0 usage.
            var applications = snapshot.applications
            for bundleId in mediaPlayingApps where applications[bundleId] == nil {
                applications[bundleId] = 0
            }
            let response = try await syncClient.sendReport(
                ReportPayload(
                    screenTime: snapshot.screenTimeSeconds,
                    applications: applications,
                    activeApps: snapshot.activeApps,
                    mediaPlayingApps: mediaPlayingApps
                ),
                registration: registration
            )

            lastReportDescription = "\(DiagnosticsLogFormatting.timestamp()) via \(reason)"
            lastDeviceState = response.deviceState
            lifecycleController?.updateServerDeviceState(response.deviceState, extra: response.extra)
            await refreshBlockedAppsIfNeeded(reason: reason, deviceState: response.deviceState)
            await refreshBlockedPlaybackAppsIfNeeded(reason: reason, deviceState: response.deviceState)
            // Lifecycle commands (DISABLE/UNINSTALL) are handled separately from the
            // deduplicated command queue. They are one-shot actions whose effect (process
            // shutdown) is not persisted, so routing them through the INSERT-OR-IGNORE queue
            // would cause them to be silently skipped after a restart — leaving the agent
            // running while the server keeps redelivering the command. Driving them directly
            // from each report response makes shutdown robust across restarts.
            let lifecycleCommands = response.serverCommands.filter { lifecycleAction(for: $0.commandName) != nil }
            let queueCommands = response.serverCommands.filter { lifecycleAction(for: $0.commandName) == nil }
            try storeIncomingCommands(queueCommands, reason: reason)
            lastErrorMessage = nil
            syncStatus = snapshot.isEligibleForReporting ? "Healthy" : "Paused"
            let commandsDescription = response.serverCommands.isEmpty
                ? "no commands"
                : response.serverCommands.map(\.commandName).joined(separator: ", ")
            recordLog("Sent report (\(reason)) with \(snapshot.applications.count) apps and state \(response.deviceState), commands: \(commandsDescription)")
            await processPendingCommands(reason: "report \(reason)")
            await handleLifecycleCommands(lifecycleCommands, reason: "report \(reason)", registration: registration)

            return .success(
                deviceState: response.deviceState,
                extra: response.extra,
                serverCommands: response.serverCommands
            )
        } catch let error as URLError {
            syncStatus = "Error"
            lastErrorMessage = error.localizedDescription
            DiagnosticsLogger.record(error: error, context: "Usage report failed")
            recordLog("Report failed (\(reason)): \(error.localizedDescription)")
            return force ? .unreachable : nil
        } catch {
            syncStatus = "Error"
            lastErrorMessage = error.localizedDescription
            DiagnosticsLogger.record(error: error, context: "Usage report failed")
            recordLog("Report failed (\(reason)): \(error.localizedDescription)")
            if force {
                if case ServerSyncClientError.invalidServerResponse = error {
                    return .unreachable
                }
                return .error(error.localizedDescription)
            }
            return nil
        }
    }

    private func runMediaPlayingLoop() async {
        while !Task.isCancelled {
            let apps = await currentMediaPlayingApps()
            recordLog("mediaPlayingLoop: detected=\(apps)")
            mediaPlayingApps = apps
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func currentMediaPlayingApps() async -> Set<String> {
        // NOTE: Returns a Set with at most 1 element — MediaRemote only reports a single
        // now-playing app at a time.
        guard let snapshot = playbackProbe.snapshot(), snapshot.isPlaying else {
            return []
        }
        // Register the playing app as known so it appears in ClientInfo even with 0 usage time.
        let appName = snapshot.name ?? snapshot.identifier
        activityMonitor.registerKnownApp(identifier: snapshot.identifier, name: appName)
        return [snapshot.identifier]
    }

    func recordUninstallLog(_ message: String) {
        recordLog(message)
    }

    private func refreshBlockedAppsIfNeeded(reason: String, deviceState: String) async {
        guard let registration else { return }

        let normalized = LifecycleStateBridge.normalize(deviceState)
        let shouldFetch = normalized == "BLOCK_RESTRICTED_APPS" || normalized == "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT"

        guard shouldFetch else {
            if !blockedAppIdentifiers.isEmpty || !blockedAppNames.isEmpty {
                blockedAppIdentifiers = []
                blockedAppNames = [:]
                recordLog("Cleared blocked-app cache after state \(normalized)")
            }
            return
        }

        // Fetch (or re-fetch) blocked apps on every report while in BLOCK state so that
        // changes the parent makes to the blocked list are picked up without requiring a
        // state transition.
        guard !isFetchingBlockedApps else { return }
        isFetchingBlockedApps = true
        defer { isFetchingBlockedApps = false }

        do {
            let apps = try await syncClient.fetchBlockedApps(registration: registration)
            blockedAppIdentifiers = Set(apps.map(\.appPath))
            blockedAppNames = apps.reduce(into: [:]) { partialResult, app in
                if let name = app.appName, !name.isEmpty {
                    partialResult[app.appPath] = name
                }
            }
            recordLog("Fetched blocked apps (\(reason)) count=\(apps.count)")
        } catch {
            lastErrorMessage = error.localizedDescription
            DiagnosticsLogger.record(error: error, context: "Blocked-app fetch failed")
            recordLog("Blocked-app fetch failed (\(reason)): \(error.localizedDescription)")
        }
    }

    private func refreshBlockedPlaybackAppsIfNeeded(reason: String, deviceState: String) async {
        guard let registration else { return }

        let normalized = LifecycleStateBridge.normalize(deviceState)
        let shouldFetch = normalized == "BLOCK_RESTRICTED_APPS" || normalized == "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT"
        let shouldEnablePlaybackBlocking = lifecycleController?.restrictedAppBlockingEnabled ?? (normalized == "BLOCK_RESTRICTED_APPS")

        guard shouldFetch else {
            await playbackBlocker.clear()
            return
        }

        if isFetchingBlockedPlaybackApps {
            await playbackBlocker.setEnabled(shouldEnablePlaybackBlocking)
            if shouldEnablePlaybackBlocking {
                await playbackBlocker.enforceIfNeeded()
            }
            return
        }

        isFetchingBlockedPlaybackApps = true
        defer { isFetchingBlockedPlaybackApps = false }

        do {
            let apps = try await syncClient.fetchBlockedPlaybackApps(registration: registration)
            await playbackBlocker.updateConfiguration(enabled: shouldEnablePlaybackBlocking, blockedApplications: apps)
            if shouldEnablePlaybackBlocking {
                await playbackBlocker.enforceIfNeeded()
            }
            recordLog("Fetched blocked playback apps (\(reason)) count=\(apps.count), enabled=\(shouldEnablePlaybackBlocking)")
        } catch {
            lastErrorMessage = error.localizedDescription
            await playbackBlocker.setEnabled(shouldEnablePlaybackBlocking)
            if shouldEnablePlaybackBlocking {
                await playbackBlocker.enforceIfNeeded()
            }
            DiagnosticsLogger.record(error: error, context: "Blocked-playback-app fetch failed")
            recordLog("Blocked-playback-app fetch failed (\(reason)): \(error.localizedDescription)")
        }
    }

    private func handleRestrictedAppBlockingActivated() async {
        guard registration != nil else { return }
        await playbackBlocker.setEnabled(true)
        await playbackBlocker.enforceIfNeeded()
        recordLog("Enabled playback blocking after restricted-app countdown")
    }

    private func processPendingCommands(reason: String) async {
        guard let registration, !isProcessingCommands else { return }

        isProcessingCommands = true
        defer {
            isProcessingCommands = false
            refreshDiagnosticsState()
        }

        do {
            let ackPending = try commandStore.commandsPendingAckUpload()
            if !ackPending.isEmpty {
                try await syncClient.sendCommandAcks(
                    CommandAcksUploadPayload(
                        acks: ackPending.map {
                            CommandAckUploadEntryPayload(
                                commandId: $0.commandId,
                                receivedAt: timestampString(Date())
                            )
                        }
                    ),
                    registration: registration
                )
                try commandStore.markAcksUploaded(commandIDs: ackPending.map(\.commandId))
                recordLog("Acknowledged \(ackPending.count) server command(s) (\(reason))")
            }

            let executionPending = try commandStore.commandsPendingExecution()
            for command in executionPending {
                let result = try execute(command: command)
                try commandStore.storeExecutionResult(result, for: command.commandId)
                lastCommandDescription = "\(command.commandName): \(result.status.lowercased())"
                recordLog("Executed server command \(command.commandName) (\(reason)): \(result.status)")
            }

            let resultPending = try commandStore.commandsPendingResultUpload()
            if !resultPending.isEmpty {
                try await syncClient.sendCommandResults(
                    CommandResultsUploadPayload(
                        results: resultPending.compactMap { command in
                            guard let result = command.executionResult else { return nil }
                            return CommandResultUploadEntryPayload(
                                commandId: command.commandId,
                                commandName: command.commandName,
                                completedAt: result.completedAt,
                                status: result.status,
                                responseType: result.responseType,
                                responsePayload: result.responsePayload
                            )
                        }
                    ),
                    registration: registration
                )
                try commandStore.markResultsUploaded(commandIDs: resultPending.map(\.commandId))
                recordLog("Uploaded \(resultPending.count) command result(s) (\(reason))")
            }

            lastErrorMessage = nil
            lastCommandErrorMessage = nil
        } catch {
            // Command processing failures are recorded separately so they don't
            // degrade the sync health indicator set by a successful client-info or report.
            lastCommandErrorMessage = error.localizedDescription
            DiagnosticsLogger.record(error: error, context: "Command processing failed")
            recordLog("Command processing failed (\(reason)): \(error.localizedDescription)")
        }
    }

    private func storeIncomingCommands(_ commands: [ServerCommandPayload], reason: String) throws {
        guard !commands.isEmpty else { return }

        let inserted = try commandStore.saveNewCommands(commands)
        if inserted > 0 {
            recordLog("Queued \(inserted) new server command(s) (\(reason))")
        }
        refreshDiagnosticsState()
    }

    private func lifecycleAction(for commandName: String) -> LifecycleShutdownAction? {
        switch commandName.uppercased() {
        case "DISABLE": return .disable
        case "UNINSTALL": return .uninstall
        default: return nil
        }
    }

    private func lifecycleResult(for action: LifecycleShutdownAction) -> StoredCommandExecutionResult {
        switch action {
        case .disable:
            return StoredCommandExecutionResult(
                completedAt: timestampString(Date()),
                status: "SUCCEEDED",
                responseType: "DISABLE_V1",
                responsePayload: [
                    "message": "Disable command accepted; agent will shut down after result upload.",
                ]
            )
        case .uninstall:
            return StoredCommandExecutionResult(
                completedAt: timestampString(Date()),
                status: "SUCCEEDED",
                responseType: "UNINSTALL_V1",
                responsePayload: [
                    "message": "Uninstall command accepted; agent will remove local state and shut down after result upload.",
                ]
            )
        }
    }

    /// Handles DISABLE/UNINSTALL commands that arrived in a report response. Unlike queue
    /// commands, lifecycle commands are not deduplicated locally: every delivery confirms the
    /// command with the server (so it stops being redelivered and a future manual relaunch
    /// behaves normally) and then triggers shutdown. Confirmation is best-effort — if it fails
    /// the agent still shuts down so the parent's intent is honoured.
    private func handleLifecycleCommands(
        _ commands: [ServerCommandPayload],
        reason: String,
        registration: RegistrationRecord
    ) async {
        guard !isLifecycleShutdownInProgress else { return }

        // UNINSTALL is the more destructive action, so prefer it if both are pending.
        let selected = commands.first { lifecycleAction(for: $0.commandName) == .uninstall }
            ?? commands.first { lifecycleAction(for: $0.commandName) == .disable }
        guard let command = selected, let action = lifecycleAction(for: command.commandName) else { return }

        isLifecycleShutdownInProgress = true
        recordLog("Received lifecycle command \(command.commandName) (\(reason)); confirming with server before shutting down")

        let result = lifecycleResult(for: action)
        do {
            try await syncClient.sendCommandAcks(
                CommandAcksUploadPayload(
                    acks: [
                        CommandAckUploadEntryPayload(
                            commandId: command.commandId,
                            receivedAt: timestampString(Date())
                        )
                    ]
                ),
                registration: registration
            )
            try await syncClient.sendCommandResults(
                CommandResultsUploadPayload(
                    results: [
                        CommandResultUploadEntryPayload(
                            commandId: command.commandId,
                            commandName: command.commandName,
                            completedAt: result.completedAt,
                            status: result.status,
                            responseType: result.responseType,
                            responsePayload: result.responsePayload
                        )
                    ]
                ),
                registration: registration
            )
            recordLog("Confirmed lifecycle command \(command.commandName) with server")
        } catch {
            DiagnosticsLogger.record(error: error, context: "Failed to confirm lifecycle command \(command.commandName)")
            recordLog("Failed to confirm lifecycle command \(command.commandName) with server: \(error.localizedDescription); shutting down anyway")
        }

        lastCommandDescription = "\(command.commandName): \(result.status.lowercased())"
        refreshDiagnosticsState()
        recordLog("Executing lifecycle command \(command.commandName) (\(reason))")
        onLifecycleShutdown?(action)
    }

    private func execute(command: StoredServerCommand) throws -> StoredCommandExecutionResult {
        switch command.commandName.uppercased() {
        case "SEND_LOGS":
            let archive = try diagnosticsLogStore.exportArchive()
            let completedAt = timestampString(Date())
            return StoredCommandExecutionResult(
                completedAt: completedAt,
                status: "SUCCEEDED",
                responseType: "SEND_LOGS_V1",
                responsePayload: [
                    "logsText": archive.text,
                    "truncated": "false",
                    "collectedAt": completedAt,
                ]
            )
        case "DISABLE":
            // Lifecycle commands are normally handled by handleLifecycleCommands and never
            // enter the queue. This case is defensive (e.g. stale queued rows) and has no
            // side effects beyond reporting success.
            return lifecycleResult(for: .disable)
        case "UNINSTALL":
            return lifecycleResult(for: .uninstall)
        default:
            return StoredCommandExecutionResult(
                completedAt: timestampString(Date()),
                status: "FAILED",
                responseType: "UNSUPPORTED_COMMAND_V1",
                responsePayload: ["receivedCommandName": command.commandName]
            )
        }
    }

    private func refreshDiagnosticsState() {
        recentLogLines = (try? diagnosticsLogStore.loadRecentLines(limit: 20)) ?? recentLogLines
        pendingCommandCount = (try? commandStore.pendingCommandCount()) ?? pendingCommandCount
    }

    /// Returns a base64-encoded PNG string for the given app bundle identifier, or nil if unavailable.
    private func iconBase64Png(for bundleIdentifier: String) -> String? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        // Resize to 64x64 to keep payload small
        let size = NSSize(width: 64, height: 64)
        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        resized.unlockFocus()
        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData.base64EncodedString()
    }

    private func recordLog(_ message: String) {
        let line = "[\(DiagnosticsLogFormatting.timestamp())] \(message)"

        do {
            try diagnosticsLogStore.append(line: line)
            recentLogLines = (try? diagnosticsLogStore.loadRecentLines(limit: 20)) ?? recentLogLines
        } catch {
            DiagnosticsLogger.record(error: error, context: "Failed to append diagnostics log line")
            recentLogLines.insert(line, at: 0)
            if recentLogLines.count > 20 {
                recentLogLines.removeLast(recentLogLines.count - 20)
            }
        }
    }

    private static let iso8601Formatter: ISO8601DateFormatter = ISO8601DateFormatter()

    private func timestampString(_ date: Date) -> String {
        SyncController.iso8601Formatter.string(from: date)
    }

    nonisolated private static func defaultAppVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }

    /// Capabilities sent in `/api/v2/client-info`.
    /// Playback reporting and blocking both require `nowplaying-cli` for MediaRemote detection.
    nonisolated static func advertisedCapabilities(nowPlayingCliInstalled: Bool = NowPlayingCliTool.isInstalled) -> [String] {
        var capabilities = [
            "SEND_LOGS_COMMAND",
            "COMMANDS_PULL",
            "DISABLE_COMMAND",
            "UNINSTALL_COMMAND",
            "ALL_MY_DEVICES_DISPLAY",
        ]
        if nowPlayingCliInstalled {
            capabilities.append(contentsOf: ["MEDIA_PLAYBACK_REPORT", "MEDIA_PLAYBACK_BLOCK"])
        }
        return capabilities
    }
}

protocol ServerCommandStoreProtocol {
    func saveNewCommands(_ commands: [ServerCommandPayload]) throws -> Int
    func commandsPendingAckUpload() throws -> [StoredServerCommand]
    func markAcksUploaded(commandIDs: [String]) throws
    func commandsPendingExecution() throws -> [StoredServerCommand]
    func storeExecutionResult(_ result: StoredCommandExecutionResult, for commandID: String) throws
    func commandsPendingResultUpload() throws -> [StoredServerCommand]
    func markResultsUploaded(commandIDs: [String]) throws
    func pendingCommandCount() throws -> Int
}

struct StoredServerCommand: Equatable {
    let commandId: String
    let commandName: String
    let issuedAt: String
    let protocolVersion: Int
    let ackUploaded: Bool
    let resultUploaded: Bool
    let executionResult: StoredCommandExecutionResult?
}

struct StoredCommandExecutionResult: Codable, Equatable {
    let completedAt: String
    let status: String
    let responseType: String
    let responsePayload: [String: String]
}

final class SQLiteServerCommandStore: ServerCommandStoreProtocol {
    private let databaseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(databaseURL: URL = AgentPersistencePaths.commandQueueDatabaseURL) {
        self.databaseURL = databaseURL
    }

    func saveNewCommands(_ commands: [ServerCommandPayload]) throws -> Int {
        guard !commands.isEmpty else { return 0 }

        return try withDatabase { database in
            try database.execute(sql: "BEGIN IMMEDIATE TRANSACTION")

            do {
                let sql = "INSERT OR IGNORE INTO server_commands(command_id, command_name, issued_at, protocol_version, ack_uploaded, result_uploaded, result_json) VALUES(?, ?, ?, ?, 0, 0, NULL)"
                var statement: OpaquePointer?

                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw CommandStoreError.prepareFailed(message: database.errorMessage)
                }

                defer { sqlite3_finalize(statement) }

                var inserted = 0
                for command in commands {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)

                    try bind(text: command.commandId, at: 1, to: statement, database: database)
                    try bind(text: command.commandName, at: 2, to: statement, database: database)
                    try bind(text: command.issuedAt, at: 3, to: statement, database: database)
                    guard sqlite3_bind_int(statement, 4, Int32(command.protocolVersion)) == SQLITE_OK else {
                        throw CommandStoreError.bindFailed(message: database.errorMessage)
                    }

                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw CommandStoreError.stepFailed(message: database.errorMessage)
                    }

                    if sqlite3_changes(database) > 0 {
                        inserted += 1
                    }
                }

                try database.execute(sql: "COMMIT TRANSACTION")
                return inserted
            } catch {
                try? database.execute(sql: "ROLLBACK TRANSACTION")
                throw error
            }
        }
    }

    func commandsPendingAckUpload() throws -> [StoredServerCommand] {
        try loadCommands(whereClause: "ack_uploaded = 0")
    }

    func markAcksUploaded(commandIDs: [String]) throws {
        try update(commandIDs: commandIDs, sql: "UPDATE server_commands SET ack_uploaded = 1 WHERE command_id = ?")
    }

    func commandsPendingExecution() throws -> [StoredServerCommand] {
        try loadCommands(whereClause: "ack_uploaded = 1 AND result_json IS NULL")
    }

    func storeExecutionResult(_ result: StoredCommandExecutionResult, for commandID: String) throws {
        let json = try String(decoding: encoder.encode(result), as: UTF8.self)
        try withDatabase { database in
            var statement: OpaquePointer?
            let sql = "UPDATE server_commands SET result_json = ? WHERE command_id = ?"

            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw CommandStoreError.prepareFailed(message: database.errorMessage)
            }

            defer { sqlite3_finalize(statement) }

            try bind(text: json, at: 1, to: statement, database: database)
            try bind(text: commandID, at: 2, to: statement, database: database)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw CommandStoreError.stepFailed(message: database.errorMessage)
            }
        }
    }

    func commandsPendingResultUpload() throws -> [StoredServerCommand] {
        try loadCommands(whereClause: "result_json IS NOT NULL AND result_uploaded = 0")
    }

    func markResultsUploaded(commandIDs: [String]) throws {
        try update(commandIDs: commandIDs, sql: "UPDATE server_commands SET result_uploaded = 1 WHERE command_id = ?")
    }

    func pendingCommandCount() throws -> Int {
        try withDatabase { database in
            var statement: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM server_commands WHERE result_uploaded = 0"

            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw CommandStoreError.prepareFailed(message: database.errorMessage)
            }

            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw CommandStoreError.stepFailed(message: database.errorMessage)
            }

            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func update(commandIDs: [String], sql: String) throws {
        guard !commandIDs.isEmpty else { return }

        try withDatabase { database in
            try database.execute(sql: "BEGIN IMMEDIATE TRANSACTION")

            do {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw CommandStoreError.prepareFailed(message: database.errorMessage)
                }

                defer { sqlite3_finalize(statement) }

                for commandID in commandIDs {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(text: commandID, at: 1, to: statement, database: database)

                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw CommandStoreError.stepFailed(message: database.errorMessage)
                    }
                }

                try database.execute(sql: "COMMIT TRANSACTION")
            } catch {
                try? database.execute(sql: "ROLLBACK TRANSACTION")
                throw error
            }
        }
    }

    private func loadCommands(whereClause: String) throws -> [StoredServerCommand] {
        try withDatabase { database in
            var statement: OpaquePointer?
            let sql = "SELECT command_id, command_name, issued_at, protocol_version, ack_uploaded, result_uploaded, result_json FROM server_commands WHERE \(whereClause) ORDER BY issued_at ASC"

            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw CommandStoreError.prepareFailed(message: database.errorMessage)
            }

            defer { sqlite3_finalize(statement) }

            var commands: [StoredServerCommand] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let commandIDCString = sqlite3_column_text(statement, 0),
                    let commandNameCString = sqlite3_column_text(statement, 1),
                    let issuedAtCString = sqlite3_column_text(statement, 2)
                else {
                    continue
                }

                let resultJSON = sqlite3_column_text(statement, 6).map { String(cString: $0) }
                let result = try resultJSON.map { json in
                    try decoder.decode(StoredCommandExecutionResult.self, from: Data(json.utf8))
                }

                commands.append(
                    StoredServerCommand(
                        commandId: String(cString: commandIDCString),
                        commandName: String(cString: commandNameCString),
                        issuedAt: String(cString: issuedAtCString),
                        protocolVersion: Int(sqlite3_column_int(statement, 3)),
                        ackUploaded: sqlite3_column_int(statement, 4) != 0,
                        resultUploaded: sqlite3_column_int(statement, 5) != 0,
                        executionResult: result
                    )
                )
            }

            return commands
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: AgentPersistencePaths.applicationSupportDirectory,
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path(percentEncoded: false), &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            throw CommandStoreError.openFailed(message: database?.errorMessage ?? "Unknown SQLite open error")
        }

        defer { sqlite3_close(database) }

        try database.execute(sql: "CREATE TABLE IF NOT EXISTS server_commands (command_id TEXT PRIMARY KEY NOT NULL, command_name TEXT NOT NULL, issued_at TEXT NOT NULL, protocol_version INTEGER NOT NULL, ack_uploaded INTEGER NOT NULL DEFAULT 0, result_uploaded INTEGER NOT NULL DEFAULT 0, result_json TEXT)")

        return try body(database)
    }

    private func bind(text: String, at index: Int32, to statement: OpaquePointer?, database: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw CommandStoreError.bindFailed(message: database.errorMessage)
        }
    }
}

private enum CommandStoreError: LocalizedError {
    case openFailed(message: String)
    case prepareFailed(message: String)
    case bindFailed(message: String)
    case stepFailed(message: String)
    case executeFailed(message: String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message):
            return "Failed to open the command queue database: \(message)"
        case let .prepareFailed(message):
            return "Failed to prepare a command queue statement: \(message)"
        case let .bindFailed(message):
            return "Failed to bind a command queue value: \(message)"
        case let .stepFailed(message):
            return "Failed to update command queue state: \(message)"
        case let .executeFailed(message):
            return "Failed to execute a command queue statement: \(message)"
        }
    }
}

private extension OpaquePointer {
    var errorMessage: String {
        guard let cString = sqlite3_errmsg(self) else {
            return "Unknown SQLite error"
        }

        return String(cString: cString)
    }

    func execute(sql: String) throws {
        guard sqlite3_exec(self, sql, nil, nil, nil) == SQLITE_OK else {
            throw CommandStoreError.executeFailed(message: errorMessage)
        }
    }
}

// SQLite does not expose SQLITE_TRANSIENT as a Swift constant. The underlying
// value is -1 cast to the destructor function pointer type, meaning SQLite will
// make its own copy of any bound string value before the call returns.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
