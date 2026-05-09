import XCTest
@testable import FamilyRulesAgent

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

    func triggerKnownAppsChanged() {
        onKnownAppsChanged?()
    }
}

private actor ServerSyncClientStub: ServerSyncClientProtocol {
    private var clientInfoCount = 0
    private var reportCount = 0

    func sendClientInfo(_ payload: ClientInfoPayload, registration: RegistrationRecord) async throws {
        clientInfoCount += 1
    }

    func sendReport(_ payload: ReportPayload, registration: RegistrationRecord) async throws -> ReportResponsePayload {
        reportCount += 1
        return ReportResponsePayload(deviceState: "ACTIVE", extra: nil, serverCommands: [])
    }

    func clientInfoPayloadCount() -> Int {
        clientInfoCount
    }

    func reportPayloadCount() -> Int {
        reportCount
    }
}
