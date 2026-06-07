import XCTest
@testable import FamilyRules

@MainActor
final class SyncControllerTests: XCTestCase {
    func testStartSendsStartupClientInfoAndReportWhenActive() async throws {
        let activityMonitor = ActivityMonitorStub(
            snapshotValue: UsageSnapshot(
                screenTimeSeconds: 30,
                applications: ["com.apple.finder": 30],
                activeApps: ["com.apple.finder"],
                visibleApplications: ["com.apple.finder": 30],
                visibleApps: ["com.apple.finder"],
                knownApps: ["com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder")],
                isEligibleForReporting: true
            )
        )
        let client = ServerSyncClientStub()
        let controller = SyncController(
            activityMonitor: activityMonitor,
            syncClient: client,
            appVersionProvider: { "1.0.0" },
            timezoneProvider: { 0 },
            automaticLoops: false
        )

        await controller.start(registration: registration)

        let clientInfoPayloadCount = await client.clientInfoPayloadCount()
        let reportPayloadCount = await client.reportPayloadCount()

        XCTAssertEqual(clientInfoPayloadCount, 1)
        XCTAssertEqual(reportPayloadCount, 1)
        XCTAssertEqual(controller.syncStatus, "Healthy")
        XCTAssertEqual(controller.lastDeviceState, "ACTIVE")
        let lastClientInfoPayloadValue = await client.lastClientInfoPayload()
        let lastClientInfoPayload = try XCTUnwrap(lastClientInfoPayloadValue)
        XCTAssertEqual(lastClientInfoPayload.capabilities, ["LOGS_COMMAND", "COMMANDS_PULL", "MEDIA_PLAYBACK_REPORT", "MEDIA_PLAYBACK_BLOCK"])
    }

    func testStartSkipsReportWhenInactive() async throws {
        let activityMonitor = ActivityMonitorStub(
            snapshotValue: UsageSnapshot(
                screenTimeSeconds: 30,
                applications: ["com.apple.finder": 30],
                activeApps: [],
                visibleApplications: [:],
                visibleApps: [],
                knownApps: ["com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder")],
                isEligibleForReporting: false
            )
        )
        let client = ServerSyncClientStub()
        let controller = SyncController(
            activityMonitor: activityMonitor,
            syncClient: client,
            appVersionProvider: { "1.0.0" },
            timezoneProvider: { 0 },
            automaticLoops: false
        )

        await controller.start(registration: registration)

        let clientInfoPayloadCount = await client.clientInfoPayloadCount()
        let reportPayloadCount = await client.reportPayloadCount()

        XCTAssertEqual(clientInfoPayloadCount, 1)
        XCTAssertEqual(reportPayloadCount, 0)
        XCTAssertEqual(controller.syncStatus, "Paused")
    }

    func testKnownAppChangeTriggersImmediateClientInfo() async throws {
        let activityMonitor = ActivityMonitorStub(
            snapshotValue: UsageSnapshot(
                screenTimeSeconds: 30,
                applications: ["com.apple.finder": 30],
                activeApps: ["com.apple.finder"],
                visibleApplications: ["com.apple.finder": 30],
                visibleApps: ["com.apple.finder"],
                knownApps: ["com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder")],
                isEligibleForReporting: true
            )
        )
        let client = ServerSyncClientStub()
        let controller = SyncController(
            activityMonitor: activityMonitor,
            syncClient: client,
            appVersionProvider: { "1.0.0" },
            timezoneProvider: { 0 },
            automaticLoops: false
        )

        await controller.start(registration: registration)
        activityMonitor.triggerKnownAppsChanged()
        for _ in 0..<10 {
            if await client.clientInfoPayloadCount() == 2 {
                break
            }

            await Task.yield()
        }

        let clientInfoPayloadCount = await client.clientInfoPayloadCount()
        XCTAssertEqual(clientInfoPayloadCount, 2)
    }

    func testAdminDisabledStateSkipsSubsequentSyncWork() async throws {
        let activityMonitor = ActivityMonitorStub(
            snapshotValue: UsageSnapshot(
                screenTimeSeconds: 30,
                applications: ["com.apple.finder": 30],
                activeApps: ["com.apple.finder"],
                visibleApplications: ["com.apple.finder": 30],
                visibleApps: ["com.apple.finder"],
                knownApps: ["com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder")],
                isEligibleForReporting: true
            )
        )
        let client = ServerSyncClientStub(reportResponse: ReportResponsePayload(deviceState: "APP_DISABLED", extra: nil, serverCommands: []))
        let lifecycleController = LifecycleControllerStub()
        let controller = SyncController(
            activityMonitor: activityMonitor,
            syncClient: client,
            lifecycleController: lifecycleController,
            appVersionProvider: { "1.0.0" },
            timezoneProvider: { 0 },
            automaticLoops: false
        )

        await controller.start(registration: registration)
        lifecycleController.markAdminDisabledFromServerState()
        await controller.sendClientInfo(reason: "manual")
        await controller.sendReportIfEligible(reason: "manual")

        let clientInfoCount = await client.clientInfoPayloadCount()
        let reportCount = await client.reportPayloadCount()
        XCTAssertEqual(clientInfoCount, 1)
        XCTAssertEqual(reportCount, 1)
        XCTAssertEqual(controller.syncStatus, "Admin Disabled")
    }

    func testRestrictedAppStateFetchesBlockedAppsAndCachesIdentifiers() async throws {
        let activityMonitor = ActivityMonitorStub(
            snapshotValue: UsageSnapshot(
                screenTimeSeconds: 30,
                applications: ["com.apple.finder": 30],
                activeApps: ["com.apple.finder"],
                visibleApplications: ["com.apple.finder": 30],
                visibleApps: ["com.apple.finder"],
                knownApps: ["com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder")],
                isEligibleForReporting: true
            )
        )
        let client = ServerSyncClientStub(
            reportResponse: ReportResponsePayload(deviceState: "BLOCK_RESTRICTED_APPS", extra: nil, serverCommands: []),
            blockedApps: [BlockedAppPayload(appPath: "com.blocked.app", appName: "Blocked App")]
        )
        let lifecycleController = LifecycleControllerStub()
        let playbackBlocker = PlaybackBlockerStub()
        let controller = SyncController(
            activityMonitor: activityMonitor,
            syncClient: client,
            lifecycleController: lifecycleController,
            playbackBlocker: playbackBlocker,
            appVersionProvider: { "1.0.0" },
            timezoneProvider: { 0 },
            automaticLoops: false
        )

        await controller.start(registration: registration)

        XCTAssertEqual(controller.blockedAppIdentifiers, ["com.blocked.app"])
        XCTAssertEqual(controller.blockedAppNames["com.blocked.app"], "Blocked App")
        let blockedAppsFetchCount = await client.blockedAppsFetchCount()
        let blockedPlaybackAppsFetchCount = await client.blockedPlaybackAppsFetchCount()
        let playbackUpdateCount = await playbackBlocker.updateConfigurationCallCount()
        let playbackEnabled = await playbackBlocker.lastEnabledValue()
        XCTAssertEqual(blockedAppsFetchCount, 1)
        XCTAssertEqual(blockedPlaybackAppsFetchCount, 1)
        XCTAssertTrue(lifecycleController.restrictedAppBlockingEnabled)
        XCTAssertEqual(playbackUpdateCount, 1)
        XCTAssertEqual(playbackEnabled, true)
    }

    func testLeavingRestrictedAppStateClearsBlockedAppCache() async throws {
        let activityMonitor = ActivityMonitorStub(
            snapshotValue: UsageSnapshot(
                screenTimeSeconds: 30,
                applications: ["com.apple.finder": 30],
                activeApps: ["com.apple.finder"],
                visibleApplications: ["com.apple.finder": 30],
                visibleApps: ["com.apple.finder"],
                knownApps: ["com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder")],
                isEligibleForReporting: true
            )
        )
        let client = ServerSyncClientStub(
            reportResponse: ReportResponsePayload(deviceState: "BLOCK_RESTRICTED_APPS", extra: nil, serverCommands: []),
            blockedApps: [BlockedAppPayload(appPath: "com.blocked.app", appName: "Blocked App")]
        )
        let lifecycleController = LifecycleControllerStub()
        let playbackBlocker = PlaybackBlockerStub()
        let controller = SyncController(
            activityMonitor: activityMonitor,
            syncClient: client,
            lifecycleController: lifecycleController,
            playbackBlocker: playbackBlocker,
            appVersionProvider: { "1.0.0" },
            timezoneProvider: { 0 },
            automaticLoops: false
        )

        await controller.start(registration: registration)
        let clearCountAfterStart = await playbackBlocker.clearCallCount()
        await client.setReportResponse(ReportResponsePayload(deviceState: "ACTIVE", extra: nil, serverCommands: []))
        await controller.sendReportIfEligible(reason: "manual")

        let playbackClearCount = await playbackBlocker.clearCallCount()
        let playbackEnabled = await playbackBlocker.lastEnabledValue()
        XCTAssertTrue(controller.blockedAppIdentifiers.isEmpty)
        XCTAssertTrue(controller.blockedAppNames.isEmpty)
        XCTAssertEqual(playbackClearCount, clearCountAfterStart + 1)
        XCTAssertEqual(playbackEnabled, false)
    }

    func testRestrictedAppTimeoutStateFetchesPlaybackAppsButKeepsPlaybackBlockingDisabledUntilCountdownCompletes() async throws {
        let activityMonitor = ActivityMonitorStub(
            snapshotValue: UsageSnapshot(
                screenTimeSeconds: 30,
                applications: ["com.apple.finder": 30],
                activeApps: ["com.apple.finder"],
                visibleApplications: ["com.apple.finder": 30],
                visibleApps: ["com.apple.finder"],
                knownApps: ["com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder")],
                isEligibleForReporting: true
            )
        )
        let client = ServerSyncClientStub(
            reportResponse: ReportResponsePayload(deviceState: "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT", extra: "30", serverCommands: []),
            blockedApps: [BlockedAppPayload(appPath: "com.blocked.app", appName: "Blocked App")],
            blockedPlaybackApps: [BlockedAppPayload(appPath: "com.microsoft.edgemac", appName: "Microsoft Edge")]
        )
        let lifecycleController = LifecycleControllerStub()
        let playbackBlocker = PlaybackBlockerStub()
        let controller = SyncController(
            activityMonitor: activityMonitor,
            syncClient: client,
            lifecycleController: lifecycleController,
            playbackBlocker: playbackBlocker,
            appVersionProvider: { "1.0.0" },
            timezoneProvider: { 0 },
            automaticLoops: false
        )

        await controller.start(registration: registration)

        let playbackInitiallyEnabled = await playbackBlocker.lastEnabledValue()
        let blockedPlaybackIdentifiers = await playbackBlocker.lastBlockedApplicationIdentifiers()
        XCTAssertEqual(playbackInitiallyEnabled, false)
        XCTAssertEqual(blockedPlaybackIdentifiers, ["com.microsoft.edgemac"])

        lifecycleController.triggerRestrictedAppBlockingActivated()
        for _ in 0..<10 {
            if await playbackBlocker.setEnabledCallCount() > 0 {
                break
            }
            await Task.yield()
        }

        let playbackEnabledAfterCountdown = await playbackBlocker.lastEnabledValue()
        let playbackEnforcementCount = await playbackBlocker.enforceIfNeededCallCount()
        XCTAssertEqual(playbackEnabledAfterCountdown, true)
        XCTAssertEqual(playbackEnforcementCount, 1)
    }

    func testRestrictedAppEnforcementStatePersistsOverlayUntilAppStopsBeingVisible() {
        var state = RestrictedAppEnforcementState()

        let initial = state.reconcile(
            restrictedAppBlockingEnabled: true,
            frontmostAppIdentifier: "com.blocked.app",
            visibleAppIdentifiers: ["com.blocked.app"],
            blockedAppIdentifiers: ["com.blocked.app"]
        )
        let persisted = state.reconcile(
            restrictedAppBlockingEnabled: true,
            frontmostAppIdentifier: "com.apple.finder",
            visibleAppIdentifiers: ["com.blocked.app", "com.apple.finder"],
            blockedAppIdentifiers: ["com.blocked.app"]
        )
        let dismissed = state.reconcile(
            restrictedAppBlockingEnabled: true,
            frontmostAppIdentifier: "com.apple.finder",
            visibleAppIdentifiers: ["com.apple.finder"],
            blockedAppIdentifiers: ["com.blocked.app"]
        )

        XCTAssertEqual(initial, "com.blocked.app")
        XCTAssertEqual(persisted, "com.blocked.app")
        XCTAssertNil(dismissed)
    }

    func testSendLogsCommandIsAcknowledgedExecutedAndUploaded() async throws {
        let activityMonitor = ActivityMonitorStub(
            snapshotValue: UsageSnapshot(
                screenTimeSeconds: 30,
                applications: ["com.apple.finder": 30],
                activeApps: ["com.apple.finder"],
                visibleApplications: ["com.apple.finder": 30],
                visibleApps: ["com.apple.finder"],
                knownApps: ["com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder")],
                isEligibleForReporting: true
            )
        )
        let client = ServerSyncClientStub(
            reportResponse: ReportResponsePayload(
                deviceState: "ACTIVE",
                extra: nil,
                serverCommands: [ServerCommandPayload(commandId: "cmd-1", commandName: "SEND_LOGS", issuedAt: "2026-05-09T10:00:00Z", protocolVersion: 1)]
            )
        )
        let commandStore = InMemoryServerCommandStore()
        let diagnosticsLogStore = DiagnosticsLogStoreStub(lines: ["[10:00:00 AM] Existing log line"])
        let controller = SyncController(
            activityMonitor: activityMonitor,
            syncClient: client,
            commandStore: commandStore,
            diagnosticsLogStore: diagnosticsLogStore,
            appVersionProvider: { "1.0.0" },
            timezoneProvider: { 0 },
            automaticLoops: false
        )

        await controller.start(registration: registration)

        let ackPayloadValue = await client.lastCommandAcksPayload()
        let ackPayload = try XCTUnwrap(ackPayloadValue)
        XCTAssertEqual(ackPayload.commandAcks.map(\.commandId), ["cmd-1"])

        let resultPayloadValue = await client.lastCommandResultsPayload()
        let resultPayload = try XCTUnwrap(resultPayloadValue)
        XCTAssertEqual(resultPayload.commandResults.map(\.commandId), ["cmd-1"])
        XCTAssertEqual(resultPayload.commandResults.first?.status, "COMPLETED")
        let uploadedLogs = try XCTUnwrap(resultPayload.commandResults.first?.details["logs"])
        XCTAssertTrue(uploadedLogs.contains("Existing log line"))
        let uploadedLineCountString = try XCTUnwrap(resultPayload.commandResults.first?.details["lineCount"])
        XCTAssertGreaterThan(Int(uploadedLineCountString) ?? 0, 0)
        XCTAssertEqual(controller.pendingCommandCount, 0)
        XCTAssertEqual(controller.lastCommandDescription, "SEND_LOGS: completed")
    }

    func testUnknownCommandProducesFailedResult() async throws {
        let activityMonitor = ActivityMonitorStub(
            snapshotValue: UsageSnapshot(
                screenTimeSeconds: 30,
                applications: ["com.apple.finder": 30],
                activeApps: ["com.apple.finder"],
                visibleApplications: ["com.apple.finder": 30],
                visibleApps: ["com.apple.finder"],
                knownApps: ["com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder")],
                isEligibleForReporting: true
            )
        )
        let client = ServerSyncClientStub(
            reportResponse: ReportResponsePayload(
                deviceState: "ACTIVE",
                extra: nil,
                serverCommands: [ServerCommandPayload(commandId: "cmd-2", commandName: "UNKNOWN_COMMAND", issuedAt: "2026-05-09T10:00:00Z", protocolVersion: 1)]
            )
        )
        let commandStore = InMemoryServerCommandStore()
        let controller = SyncController(
            activityMonitor: activityMonitor,
            syncClient: client,
            commandStore: commandStore,
            diagnosticsLogStore: DiagnosticsLogStoreStub(),
            appVersionProvider: { "1.0.0" },
            timezoneProvider: { 0 },
            automaticLoops: false
        )

        await controller.start(registration: registration)

        let resultPayloadValue = await client.lastCommandResultsPayload()
        let resultPayload = try XCTUnwrap(resultPayloadValue)
        XCTAssertEqual(resultPayload.commandResults.map(\.commandId), ["cmd-2"])
        XCTAssertEqual(resultPayload.commandResults.first?.status, "FAILED")
        XCTAssertEqual(resultPayload.commandResults.first?.details["commandName"], "UNKNOWN_COMMAND")
        XCTAssertEqual(controller.pendingCommandCount, 0)
        XCTAssertEqual(controller.lastCommandDescription, "UNKNOWN_COMMAND: failed")
    }

    func testPendingCommandRetriesAfterRestartWhenAckUploadInitiallyFails() async throws {
        let sharedCommandStore = InMemoryServerCommandStore()
        let diagnosticsLogStore = DiagnosticsLogStoreStub(lines: ["[10:00:00 AM] Existing log line"])
        let activityMonitor = ActivityMonitorStub(
            snapshotValue: UsageSnapshot(
                screenTimeSeconds: 30,
                applications: ["com.apple.finder": 30],
                activeApps: ["com.apple.finder"],
                visibleApplications: ["com.apple.finder": 30],
                visibleApps: ["com.apple.finder"],
                knownApps: ["com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder")],
                isEligibleForReporting: true
            )
        )
        let firstClient = ServerSyncClientStub(
            reportResponse: ReportResponsePayload(
                deviceState: "ACTIVE",
                extra: nil,
                serverCommands: [ServerCommandPayload(commandId: "cmd-1", commandName: "SEND_LOGS", issuedAt: "2026-05-09T10:00:00Z", protocolVersion: 1)]
            ),
            failCommandAckUploads: 1
        )
        let firstController = SyncController(
            activityMonitor: activityMonitor,
            syncClient: firstClient,
            commandStore: sharedCommandStore,
            diagnosticsLogStore: diagnosticsLogStore,
            appVersionProvider: { "1.0.0" },
            timezoneProvider: { 0 },
            automaticLoops: false
        )

        await firstController.start(registration: registration)

        XCTAssertEqual(firstController.pendingCommandCount, 1)
        XCTAssertNotNil(firstController.lastCommandErrorMessage)
        let firstResultPayload = await firstClient.lastCommandResultsPayload()
        XCTAssertNil(firstResultPayload)

        let secondClient = ServerSyncClientStub()
        let secondController = SyncController(
            activityMonitor: activityMonitor,
            syncClient: secondClient,
            commandStore: sharedCommandStore,
            diagnosticsLogStore: diagnosticsLogStore,
            appVersionProvider: { "1.0.0" },
            timezoneProvider: { 0 },
            automaticLoops: false
        )

        await secondController.start(registration: registration)

        let retriedAckPayloadValue = await secondClient.lastCommandAcksPayload()
        let retriedAckPayload = try XCTUnwrap(retriedAckPayloadValue)
        XCTAssertEqual(retriedAckPayload.commandAcks.map(\.commandId), ["cmd-1"])

        let retriedResultPayloadValue = await secondClient.lastCommandResultsPayload()
        let retriedResultPayload = try XCTUnwrap(retriedResultPayloadValue)
        XCTAssertEqual(retriedResultPayload.commandResults.map(\.commandId), ["cmd-1"])
        XCTAssertEqual(secondController.pendingCommandCount, 0)
    }

    private var registration: RegistrationRecord {
        RegistrationRecord(
            serverURL: "https://example.com",
            username: "parent",
            instanceId: "instance-1",
            instanceToken: "token-1",
            instanceName: "Desk Mac"
        )
    }
}

@MainActor
private final class ActivityMonitorStub: ActivityMonitorProtocol {
    var onKnownAppsChanged: (() -> Void)?
    var snapshotValue: UsageSnapshot

    init(snapshotValue: UsageSnapshot) {
        self.snapshotValue = snapshotValue
    }

    func start() {}

    func stop() {}

    func snapshot() -> UsageSnapshot {
        snapshotValue
    }

    func registerKnownApp(identifier: String, name: String) {}

    func triggerKnownAppsChanged() {
        onKnownAppsChanged?()
    }
}

private actor ServerSyncClientStub: ServerSyncClientProtocol {
    private var clientInfoCount = 0
    private var reportCount = 0
    private var blockedAppsCount = 0
    private var blockedPlaybackAppsCount = 0
    private var commandAckCount = 0
    private var commandResultCount = 0
    private var reportResponse: ReportResponsePayload
    private let blockedApps: [BlockedAppPayload]
    private let blockedPlaybackApps: [BlockedAppPayload]
    private var lastClientInfoPayloadValue: ClientInfoPayload?
    private var lastCommandAcksPayloadValue: CommandAcksUploadPayload?
    private var lastCommandResultsPayloadValue: CommandResultsUploadPayload?
    private var remainingCommandAckFailures: Int

    init(
        reportResponse: ReportResponsePayload = ReportResponsePayload(deviceState: "ACTIVE", extra: nil, serverCommands: []),
        blockedApps: [BlockedAppPayload] = [],
        blockedPlaybackApps: [BlockedAppPayload] = [],
        failCommandAckUploads: Int = 0
    ) {
        self.reportResponse = reportResponse
        self.blockedApps = blockedApps
        self.blockedPlaybackApps = blockedPlaybackApps
        self.remainingCommandAckFailures = failCommandAckUploads
    }

    func sendClientInfo(_ payload: ClientInfoPayload, registration: RegistrationRecord) async throws {
        clientInfoCount += 1
        lastClientInfoPayloadValue = payload
    }

    func sendReport(_ payload: ReportPayload, registration: RegistrationRecord) async throws -> ReportResponsePayload {
        reportCount += 1
        return reportResponse
    }

    func fetchBlockedApps(registration: RegistrationRecord) async throws -> [BlockedAppPayload] {
        blockedAppsCount += 1
        return blockedApps
    }

    func fetchBlockedPlaybackApps(registration: RegistrationRecord) async throws -> [BlockedAppPayload] {
        blockedPlaybackAppsCount += 1
        return blockedPlaybackApps
    }

    func sendCommandAcks(_ payload: CommandAcksUploadPayload, registration: RegistrationRecord) async throws {
        commandAckCount += 1
        lastCommandAcksPayloadValue = payload

        if remainingCommandAckFailures > 0 {
            remainingCommandAckFailures -= 1
            throw ServerSyncClientError.requestFailed(statusCode: 500)
        }
    }

    func sendCommandResults(_ payload: CommandResultsUploadPayload, registration: RegistrationRecord) async throws {
        commandResultCount += 1
        lastCommandResultsPayloadValue = payload
    }

    func clientInfoPayloadCount() -> Int {
        clientInfoCount
    }

    func lastClientInfoPayload() -> ClientInfoPayload? {
        lastClientInfoPayloadValue
    }

    func reportPayloadCount() -> Int {
        reportCount
    }

    func blockedAppsFetchCount() -> Int {
        blockedAppsCount
    }

    func blockedPlaybackAppsFetchCount() -> Int {
        blockedPlaybackAppsCount
    }

    func lastCommandAcksPayload() -> CommandAcksUploadPayload? {
        lastCommandAcksPayloadValue
    }

    func lastCommandResultsPayload() -> CommandResultsUploadPayload? {
        lastCommandResultsPayloadValue
    }

    func setReportResponse(_ response: ReportResponsePayload) {
        reportResponse = response
    }
}

private final class InMemoryServerCommandStore: ServerCommandStoreProtocol {
    private var commands: [String: StoredServerCommand] = [:]

    func saveNewCommands(_ commands: [ServerCommandPayload]) throws -> Int {
        var inserted = 0
        for command in commands {
            if self.commands[command.commandId] == nil {
                self.commands[command.commandId] = StoredServerCommand(
                    commandId: command.commandId,
                    commandName: command.commandName,
                    issuedAt: command.issuedAt,
                    protocolVersion: command.protocolVersion,
                    ackUploaded: false,
                    resultUploaded: false,
                    executionResult: nil
                )
                inserted += 1
            }
        }
        return inserted
    }

    func commandsPendingAckUpload() throws -> [StoredServerCommand] {
        commands.values.filter { !$0.ackUploaded }.sorted { $0.issuedAt < $1.issuedAt }
    }

    func markAcksUploaded(commandIDs: [String]) throws {
        for commandID in commandIDs {
            guard let command = commands[commandID] else { continue }
            commands[commandID] = StoredServerCommand(
                commandId: command.commandId,
                commandName: command.commandName,
                issuedAt: command.issuedAt,
                protocolVersion: command.protocolVersion,
                ackUploaded: true,
                resultUploaded: command.resultUploaded,
                executionResult: command.executionResult
            )
        }
    }

    func commandsPendingExecution() throws -> [StoredServerCommand] {
        commands.values.filter { $0.ackUploaded && $0.executionResult == nil }.sorted { $0.issuedAt < $1.issuedAt }
    }

    func storeExecutionResult(_ result: StoredCommandExecutionResult, for commandID: String) throws {
        guard let command = commands[commandID] else { return }
        commands[commandID] = StoredServerCommand(
            commandId: command.commandId,
            commandName: command.commandName,
            issuedAt: command.issuedAt,
            protocolVersion: command.protocolVersion,
            ackUploaded: command.ackUploaded,
            resultUploaded: false,
            executionResult: result
        )
    }

    func commandsPendingResultUpload() throws -> [StoredServerCommand] {
        commands.values.filter { !$0.resultUploaded && $0.executionResult != nil }.sorted { $0.issuedAt < $1.issuedAt }
    }

    func markResultsUploaded(commandIDs: [String]) throws {
        for commandID in commandIDs {
            guard let command = commands[commandID] else { continue }
            commands[commandID] = StoredServerCommand(
                commandId: command.commandId,
                commandName: command.commandName,
                issuedAt: command.issuedAt,
                protocolVersion: command.protocolVersion,
                ackUploaded: command.ackUploaded,
                resultUploaded: true,
                executionResult: command.executionResult
            )
        }
    }

    func pendingCommandCount() throws -> Int {
        commands.values.filter { !$0.resultUploaded }.count
    }
}

private final class DiagnosticsLogStoreStub: DiagnosticsLogStoreProtocol {
    private var lines: [String]

    init(lines: [String] = []) {
        self.lines = lines
    }

    func loadRecentLines(limit: Int) throws -> [String] {
        Array(lines.suffix(limit).reversed())
    }

    func append(line: String) throws {
        lines.append(line)
    }

    func exportArchive() throws -> DiagnosticsLogArchive {
        DiagnosticsLogArchive(text: lines.joined(separator: "\n"), lineCount: lines.count)
    }
}

@MainActor
private final class LifecycleControllerStub: LifecycleControlling {
    private(set) var isAdminDisabled = false
    private(set) var statusDescription = "Inactive"
    private(set) var loginItemStatusDescription = "mainApp: notRegistered"
    private(set) var helperStatusDescription = "Unknown"
    private(set) var countdownPresentation: StateCountdownPresentation?
    private(set) var restrictedAppBlockingEnabled = false
    var onRestrictedAppBlockingActivated: (() -> Void)?
    private(set) var shouldPresentCompactCountdown = false
    private(set) var shouldEnforceSwitchUserLoop = false

    func start(registration: RegistrationRecord) {
        statusDescription = "Protected"
    }

    func updateServerDeviceState(_ rawState: String, extra: String?) {
        let normalized = LifecycleStateBridge.normalize(rawState)
        isAdminDisabled = LifecycleStateBridge.isAdminDisabled(normalized)
        restrictedAppBlockingEnabled = normalized == "BLOCK_RESTRICTED_APPS"
        statusDescription = isAdminDisabled ? "Admin Disabled" : "Protected"
    }

    func performRestrictedAppFallbackTermination(targetIdentifier: String) async -> Bool {
        true
    }

    func stop() {
        isAdminDisabled = false
        statusDescription = "Inactive"
        restrictedAppBlockingEnabled = false
    }

    func refreshDiagnostics() async {}

    func triggerRestrictedAppBlockingActivated() {
        restrictedAppBlockingEnabled = true
        onRestrictedAppBlockingActivated?()
    }

    func markAdminDisabledFromServerState() {
        updateServerDeviceState("APP_DISABLED", extra: nil)
    }
}

private actor PlaybackBlockerStub: PlaybackBlockingProtocol {
    private var updateCalls = 0
    private var setEnabledCalls = 0
    private var clearCalls = 0
    private var enforceCalls = 0
    private var enabled = false
    private var blockedApplicationIdentifiers: Set<String> = []

    func updateConfiguration(enabled: Bool, blockedApplications: [BlockedAppPayload]) async {
        updateCalls += 1
        self.enabled = enabled
        blockedApplicationIdentifiers = Set(blockedApplications.map(\.appPath))
    }

    func setEnabled(_ enabled: Bool) async {
        setEnabledCalls += 1
        self.enabled = enabled
    }

    func clear() async {
        clearCalls += 1
        enabled = false
        blockedApplicationIdentifiers = []
    }

    func enforceIfNeeded() async {
        enforceCalls += 1
    }

    func updateConfigurationCallCount() -> Int {
        updateCalls
    }

    func setEnabledCallCount() -> Int {
        setEnabledCalls
    }

    func clearCallCount() -> Int {
        clearCalls
    }

    func enforceIfNeededCallCount() -> Int {
        enforceCalls
    }

    func lastEnabledValue() -> Bool {
        enabled
    }

    func lastBlockedApplicationIdentifiers() -> Set<String> {
        blockedApplicationIdentifiers
    }
}
