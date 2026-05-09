import Foundation

@MainActor
final class SyncController: ObservableObject {
    @Published private(set) var syncStatus = "Idle"
    @Published private(set) var lastClientInfoDescription = "Never"
    @Published private(set) var lastReportDescription = "Never"
    @Published private(set) var lastDeviceState = "Unknown"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var recentLogLines: [String] = []

    private let activityMonitor: any ActivityMonitorProtocol
    private let syncClient: any ServerSyncClientProtocol
    private let appVersionProvider: () -> String
    private let timezoneProvider: () -> Int
    private let clientInfoIntervalSeconds: Int
    private let reportIntervalSeconds: Int
    private let automaticLoops: Bool
    private let sleep: @Sendable (Int) async throws -> Void

    private var registration: RegistrationRecord?
    private var clientInfoTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var isSendingClientInfo = false
    private var isSendingReport = false

    init(
        activityMonitor: any ActivityMonitorProtocol,
        syncClient: any ServerSyncClientProtocol = ServerSyncClient(),
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
        self.appVersionProvider = appVersionProvider
        self.timezoneProvider = timezoneProvider
        self.clientInfoIntervalSeconds = clientInfoIntervalSeconds
        self.reportIntervalSeconds = reportIntervalSeconds
        self.automaticLoops = automaticLoops
        self.sleep = sleep
    }

    func start(registration: RegistrationRecord) async {
        stop()

        self.registration = registration
        syncStatus = "Starting"
        recordLog("Starting sync for \(registration.instanceName)")

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
    }

    func stop() {
        clientInfoTask?.cancel()
        reportTask?.cancel()
        clientInfoTask = nil
        reportTask = nil
        registration = nil
        activityMonitor.onKnownAppsChanged = nil

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

    private func sendClientInfo(reason: String) async {
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
            ],
            timezoneOffsetSeconds: timezoneProvider(),
            reportIntervalSeconds: reportIntervalSeconds,
            knownApps: snapshot.knownApps.mapValues { KnownAppPayload(appName: $0.name, iconBase64Png: nil) },
            supportedServerCommands: []
        )

        do {
            try await syncClient.sendClientInfo(payload, registration: registration)
            lastClientInfoDescription = "\(timestamp()) via \(reason)"
            lastErrorMessage = nil
            syncStatus = syncStatus == "Paused" ? "Paused" : "Healthy"
            recordLog("Sent client-info (\(reason)) with \(payload.knownApps.count) known apps")
        } catch {
            syncStatus = "Error"
            lastErrorMessage = error.localizedDescription
            recordLog("Client-info failed (\(reason)): \(error.localizedDescription)")
        }
    }

    private func sendReportIfEligible(reason: String) async {
        guard let registration, !isSendingReport else { return }

        let snapshot = activityMonitor.snapshot()
        guard snapshot.isEligibleForReporting else {
            syncStatus = "Paused"
            return
        }

        isSendingReport = true
        defer { isSendingReport = false }

        do {
            let response = try await syncClient.sendReport(
                ReportPayload(
                    screenTime: snapshot.screenTimeSeconds,
                    applications: snapshot.applications,
                    activeApps: snapshot.activeApps
                ),
                registration: registration
            )

            lastReportDescription = "\(timestamp()) via \(reason)"
            lastDeviceState = response.deviceState
            lastErrorMessage = nil
            syncStatus = "Healthy"
            recordLog("Sent report (\(reason)) with \(snapshot.applications.count) apps and state \(response.deviceState)")
        } catch {
            syncStatus = "Error"
            lastErrorMessage = error.localizedDescription
            recordLog("Report failed (\(reason)): \(error.localizedDescription)")
        }
    }

    private func recordLog(_ message: String) {
        recentLogLines.insert("[\(timestamp())] \(message)", at: 0)

        if recentLogLines.count > 20 {
            recentLogLines.removeLast(recentLogLines.count - 20)
        }
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: Date())
    }

    nonisolated private static func defaultAppVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }
}
