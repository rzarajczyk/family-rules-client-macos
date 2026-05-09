import XCTest
@testable import FamilyRulesAgent

@MainActor
final class LifecycleControllerTests: XCTestCase {
    func testEnteringAdminDisabledUpdatesPublishedStateAndNotifiesHelper() async throws {
        let helperClient = HelperLifecycleClientStub()
        let controller = LifecycleController(
            helperClient: helperClient,
            bundleIdentifierProvider: { "com.familyrules.agent" },
            now: { Date(timeIntervalSince1970: 100) },
            loginItemRegistrar: { "mainApp: enabled" }
        )

        controller.start(registration: registration)
        try await waitForUpdateCount(helperClient, count: 1)

        controller.updateServerDeviceState("APP_DISABLED", extra: nil)
        try await waitForUpdateCount(helperClient, count: 2)

        XCTAssertTrue(controller.isAdminDisabled)
        XCTAssertEqual(controller.statusDescription, "Admin Disabled")
        let payload1 = await helperClient.lastPayload()
        let lastPayload = try XCTUnwrap(payload1)
        XCTAssertTrue(lastPayload.isAdminDisabled)
        XCTAssertEqual(lastPayload.lastObservedDeviceState, "ADMIN_DISABLED")
    }

    func testLeavingAdminDisabledRestoresProtectedState() async throws {
        let helperClient = HelperLifecycleClientStub()
        let controller = LifecycleController(
            helperClient: helperClient,
            bundleIdentifierProvider: { "com.familyrules.agent" },
            now: { Date(timeIntervalSince1970: 100) },
            loginItemRegistrar: { "mainApp: enabled" }
        )

        controller.start(registration: registration)
        try await waitForUpdateCount(helperClient, count: 1)

        controller.updateServerDeviceState("ADMIN_DISABLED", extra: nil)
        try await waitForUpdateCount(helperClient, count: 2)

        controller.updateServerDeviceState("ACTIVE", extra: nil)
        try await waitForUpdateCount(helperClient, count: 3)

        XCTAssertFalse(controller.isAdminDisabled)
        XCTAssertEqual(controller.statusDescription, "Protected")
        let payload2 = await helperClient.lastPayload()
        let lastPayload2 = try XCTUnwrap(payload2)
        XCTAssertFalse(lastPayload2.isAdminDisabled)
    }

    func testSameStateDoesNotChangeBooleanButStillPushesHeartbeat() async throws {
        // F3: heartbeat should be refreshed even when the boolean doesn't change.
        let helperClient = HelperLifecycleClientStub()
        let controller = LifecycleController(
            helperClient: helperClient,
            bundleIdentifierProvider: { "com.familyrules.agent" },
            now: { Date(timeIntervalSince1970: 100) },
            loginItemRegistrar: { "mainApp: enabled" }
        )

        controller.start(registration: registration)
        try await waitForUpdateCount(helperClient, count: 1)

        controller.updateServerDeviceState("ACTIVE", extra: nil)
        try await waitForUpdateCount(helperClient, count: 2)

        controller.updateServerDeviceState("ACTIVE", extra: nil)
        try await waitForUpdateCount(helperClient, count: 3)

        XCTAssertFalse(controller.isAdminDisabled)
        let count = await helperClient.updateCallCount()
        XCTAssertEqual(count, 3)
    }

    func testStopNotifiesHelperWithAdminDisabledFalse() async throws {
        // F5: stop() must push a final payload so the helper clears its timer.
        let helperClient = HelperLifecycleClientStub()
        let controller = LifecycleController(
            helperClient: helperClient,
            bundleIdentifierProvider: { "com.familyrules.agent" },
            now: { Date(timeIntervalSince1970: 100) },
            loginItemRegistrar: { "mainApp: enabled" }
        )

        controller.start(registration: registration)
        controller.updateServerDeviceState("ADMIN_DISABLED", extra: nil)
        try await waitForUpdateCount(helperClient, count: 2)

        controller.stop()
        try await waitForUpdateCount(helperClient, count: 3)

        let payload3 = await helperClient.lastPayload()
        let lastPayload3 = try XCTUnwrap(payload3)
        XCTAssertFalse(lastPayload3.isAdminDisabled)
        XCTAssertEqual(lastPayload3.lastObservedDeviceState, "ACTIVE")
        XCTAssertEqual(controller.statusDescription, "Inactive")
    }

    func testLockTimeoutStateUpdatesStatusAndPushesNormalizedState() async throws {
        let helperClient = HelperLifecycleClientStub()
        let deviceStateController = DeviceStateControllerStub(statusDescription: "Locking in 30s")
        let controller = LifecycleController(
            helperClient: helperClient,
            deviceStateController: deviceStateController,
            bundleIdentifierProvider: { "com.familyrules.agent" },
            now: { Date(timeIntervalSince1970: 100) },
            loginItemRegistrar: { "mainApp: enabled" }
        )

        controller.start(registration: registration)
        try await waitForUpdateCount(helperClient, count: 1)

        controller.updateServerDeviceState("LOCKED_WITH_COUNTDOWN", extra: "30")
        try await waitForUpdateCount(helperClient, count: 2)

        XCTAssertEqual(controller.lastObservedDeviceState, "LOCK_SCREEN_WITH_TIMEOUT")
        XCTAssertEqual(controller.statusDescription, "Locking in 30s")
        let payload4 = await helperClient.lastPayload()
        let lastPayload4 = try XCTUnwrap(payload4)
        XCTAssertEqual(lastPayload4.lastObservedDeviceState, "LOCK_SCREEN_WITH_TIMEOUT")
    }

    func testRefreshDiagnosticsPopulatesHelperStatusDescription() async throws {
        // F9: refreshDiagnostics() coverage.
        let helperClient = HelperLifecycleClientStub()
        let controller = LifecycleController(
            helperClient: helperClient,
            bundleIdentifierProvider: { "com.familyrules.agent" },
            now: { Date(timeIntervalSince1970: 100) },
            loginItemRegistrar: { "mainApp: enabled" }
        )

        controller.start(registration: registration)
        await controller.refreshDiagnostics()

        XCTAssertFalse(controller.helperStatusDescription.isEmpty)
        XCTAssertTrue(controller.helperStatusDescription.contains("active"))
    }

    func testRefreshDiagnosticsShowsErrorOnHelperFailure() async throws {
        let helperClient = HelperLifecycleClientStub(fetchShouldFail: true)
        let controller = LifecycleController(
            helperClient: helperClient,
            bundleIdentifierProvider: { "com.familyrules.agent" },
            now: { Date(timeIntervalSince1970: 100) },
            loginItemRegistrar: { "mainApp: enabled" }
        )

        controller.start(registration: registration)
        await controller.refreshDiagnostics()

        XCTAssertTrue(controller.helperStatusDescription.contains("stub fetch failed"))
    }

    func testRestrictedAppFallbackTerminationDelegatesToHelper() async throws {
        let helperClient = HelperLifecycleClientStub()
        let controller = LifecycleController(
            helperClient: helperClient,
            bundleIdentifierProvider: { "com.familyrules.agent" },
            now: { Date(timeIntervalSince1970: 100) },
            loginItemRegistrar: { "mainApp: enabled" }
        )

        let didTerminate = await controller.performRestrictedAppFallbackTermination(targetIdentifier: "com.blocked.app")

        XCTAssertTrue(didTerminate)
        let request = await helperClient.lastDeviceActionRequest()
        let lastRequest = try XCTUnwrap(request)
        XCTAssertEqual(lastRequest.action, .terminateApp)
        XCTAssertEqual(lastRequest.targetIdentifier, "com.blocked.app")
    }

    // MARK: - Helpers

    private var registration: RegistrationRecord {
        RegistrationRecord(
            serverURL: "https://example.com",
            username: "parent",
            instanceId: "instance-1",
            instanceToken: "token-1",
            instanceName: "Desk Mac"
        )
    }

    /// Spins yielding until the stub's update call count reaches `count` or a timeout elapses.
    private func waitForUpdateCount(_ stub: HelperLifecycleClientStub, count: Int, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = await stub.updateCallCount()
            if current >= count { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for updateCallCount >= \(count)")
    }
}

private actor HelperLifecycleClientStub: HelperLifecycleClientProtocol {
    private(set) var lastUpdatedPayload: AgentStatusPayload?
    private(set) var lastDeviceAction: HelperDeviceActionRequest?
    private(set) var callCount = 0
    private let fetchShouldFail: Bool

    init(fetchShouldFail: Bool = false) {
        self.fetchShouldFail = fetchShouldFail
    }

    func lastPayload() -> AgentStatusPayload? {
        lastUpdatedPayload
    }

    func updateCallCount() -> Int {
        callCount
    }

    func lastDeviceActionRequest() -> HelperDeviceActionRequest? {
        lastDeviceAction
    }

    func ping() async throws -> String {
        "pong"
    }

    func updateAgentStatus(_ payload: AgentStatusPayload) async throws -> String {
        lastUpdatedPayload = payload
        callCount += 1
        return "ok"
    }

    func fetchLifecycleStatus() async throws -> HelperLifecycleStatusPayload {
        if fetchShouldFail {
            throw StubError.fetchFailed
        }
        return HelperLifecycleStatusPayload(
            isAdminDisabled: false,
            lastHeartbeatAt: nil,
            lastObservedDeviceState: "ACTIVE",
            lastPollDescription: nil,
            lastRelaunchDescription: nil,
            lastActionDescription: nil
        )
    }

    func executeDeviceAction(_ request: HelperDeviceActionRequest) async throws -> String {
        lastDeviceAction = request
        switch request.action {
        case .lockScreen:
            return "Lock requested"
        case .logout:
            return "Logout requested"
        case .terminateApp:
            return "Terminate requested for \(request.targetIdentifier ?? "unknown")"
        }
    }

    private enum StubError: LocalizedError {
        case fetchFailed
        var errorDescription: String? { "stub fetch failed" }
    }
}

@MainActor
private final class DeviceStateControllerStub: DeviceStateControlling {
    var normalizedState = "ACTIVE"
    var statusDescription: String
    var countdownPresentation: StateCountdownPresentation?
    var restrictedAppBlockingEnabled = false

    init(statusDescription: String, countdownPresentation: StateCountdownPresentation? = nil) {
        self.statusDescription = statusDescription
        self.countdownPresentation = countdownPresentation
    }

    func apply(rawState: String, extra: String?) {
        normalizedState = LifecycleStateBridge.normalize(rawState)
    }

    func clear() {
        normalizedState = "ACTIVE"
        countdownPresentation = nil
        restrictedAppBlockingEnabled = false
    }
}
