import XCTest
@testable import FamilyRules

@MainActor
final class DeviceStateControllerTests: XCTestCase {
    func testLegacyLockCountdownStateNormalizesWithoutExecutingHelperAction() async throws {
        let helperClient = HelperLifecycleClientActionStub()
        let controller = DeviceStateController(
            helperClient: helperClient,
            countdownDurationProvider: { _, _ in 2 },
            sleep: { _ in }
        )

        controller.apply(rawState: "LOCKED_WITH_COUNTDOWN", extra: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(controller.normalizedState, "LOCK_SCREEN")
        XCTAssertEqual(controller.statusDescription, String.localized("Screen Locked"))
        XCTAssertNil(controller.countdownPresentation)
        let requests = await helperClient.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testLogoutCountdownUsesExtraValueWhenPresent() async throws {
        let helperClient = HelperLifecycleClientActionStub()
        let controller = DeviceStateController(
            helperClient: helperClient,
            sessionActionExecutor: { _ in nil },
            countdownDurationProvider: { _, extra in Int(extra ?? "") ?? 60 },
            sleep: { _ in }
        )

        controller.apply(rawState: "LOGOUT_WITH_TIMEOUT", extra: "3")
        try await waitForRequestCount(helperClient, count: 1)

        XCTAssertEqual(controller.normalizedState, "LOGOUT")
        XCTAssertEqual(controller.statusDescription, "Switch user requested")
        let requests = await helperClient.recordedRequests()
        XCTAssertEqual(requests.map(\.action), [.switchUser])
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

    func testRepeatedTimeoutStateDoesNotResetActiveCountdown() async {
        let helperClient = HelperLifecycleClientActionStub()
        let now = LockedNow(date: Date(timeIntervalSince1970: 1_000))
        let controller = DeviceStateController(
            helperClient: helperClient,
            countdownDurationProvider: { _, _ in 60 },
            sleep: { _ in },
            now: { now.value }
        )

        controller.apply(rawState: "LOCK_SCREEN_WITH_TIMEOUT", extra: nil)
        XCTAssertEqual(controller.countdownPresentation?.secondsRemaining, 60)

        now.advance(by: 17)
        controller.apply(rawState: "LOCK_SCREEN_WITH_TIMEOUT", extra: nil)

        XCTAssertEqual(controller.countdownPresentation?.secondsRemaining, 43)
        XCTAssertEqual(
            controller.statusDescription,
            String(format: String.localized("Locking in %ds"), 43)
        )
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

private final class LockedNow {
    var value: Date

    init(date: Date) {
        value = date
    }

    func advance(by seconds: TimeInterval) {
        value.addTimeInterval(seconds)
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
            lastHeartbeatAt: nil,
            lastObservedDeviceState: "ACTIVE",
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
        case .switchUser:
            return "Switch user requested"
        }
    }

    func recordedRequests() -> [HelperDeviceActionRequest] {
        requests
    }
}
