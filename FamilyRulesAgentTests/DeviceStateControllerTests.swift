import XCTest
@testable import FamilyRulesAgent

@MainActor
final class DeviceStateControllerTests: XCTestCase {
    func testLegacyLockCountdownStateNormalizesAndExecutesHelperAction() async throws {
        let helperClient = HelperLifecycleClientActionStub()
        let controller = DeviceStateController(
            helperClient: helperClient,
            countdownDurationProvider: { _, _ in 2 },
            sleep: { _ in }
        )

        controller.apply(rawState: "LOCKED_WITH_COUNTDOWN", extra: nil)
        try await waitForRequestCount(helperClient, count: 1)

        XCTAssertEqual(controller.normalizedState, "LOCK_SCREEN")
        XCTAssertEqual(controller.statusDescription, "Lock requested")
        XCTAssertNil(controller.countdownPresentation)
        let requests = await helperClient.recordedRequests()
        XCTAssertEqual(requests.map(\.action), [.lockScreen])
    }

    func testLogoutCountdownUsesExtraValueWhenPresent() async throws {
        let helperClient = HelperLifecycleClientActionStub()
        let controller = DeviceStateController(
            helperClient: helperClient,
            countdownDurationProvider: { _, extra in Int(extra ?? "") ?? 60 },
            sleep: { _ in }
        )

        controller.apply(rawState: "LOGOUT_WITH_TIMEOUT", extra: "3")
        try await waitForRequestCount(helperClient, count: 1)

        XCTAssertEqual(controller.normalizedState, "LOGOUT")
        XCTAssertEqual(controller.statusDescription, "Logout requested")
        let requests = await helperClient.recordedRequests()
        XCTAssertEqual(requests.map(\.action), [.logout])
    }

    func testRestrictedAppCountdownEnablesBlockingAfterDelay() async {
        let helperClient = HelperLifecycleClientActionStub()
        let controller = DeviceStateController(
            helperClient: helperClient,
            countdownDurationProvider: { _, _ in 2 },
            sleep: { _ in }
        )

        controller.apply(rawState: "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT", extra: nil)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if controller.normalizedState == "BLOCK_RESTRICTED_APPS" { break }
            await Task.yield()
        }

        XCTAssertEqual(controller.normalizedState, "BLOCK_RESTRICTED_APPS")
        XCTAssertTrue(controller.restrictedAppBlockingEnabled)
        XCTAssertNil(controller.countdownPresentation)
        XCTAssertEqual(controller.statusDescription, "Blocking Restricted Apps")
    }

    private func waitForRequestCount(_ stub: HelperLifecycleClientActionStub, count: Int, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = await stub.recordedRequests().count
            if current >= count { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for recorded request count >= \(count)")
    }
}

private actor HelperLifecycleClientActionStub: HelperLifecycleClientProtocol {
    private var requests: [HelperDeviceActionRequest] = []

    func ping() async throws -> String {
        "pong"
    }

    func updateAgentStatus(_ payload: AgentStatusPayload) async throws -> String {
        "ok"
    }

    func fetchLifecycleStatus() async throws -> HelperLifecycleStatusPayload {
        HelperLifecycleStatusPayload(
            isAdminDisabled: false,
            lastHeartbeatAt: nil,
            lastObservedDeviceState: "ACTIVE",
            lastPollDescription: nil,
            lastRelaunchDescription: nil,
            lastActionDescription: nil
        )
    }

    func executeDeviceAction(_ request: HelperDeviceActionRequest) async throws -> String {
        requests.append(request)
        switch request.action {
        case .lockScreen:
            return "Lock requested"
        case .logout:
            return "Logout requested"
        case .terminateApp:
            return "Terminate requested"
        }
    }

    func recordedRequests() -> [HelperDeviceActionRequest] {
        requests
    }
}
