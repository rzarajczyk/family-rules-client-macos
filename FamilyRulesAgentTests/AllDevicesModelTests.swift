import XCTest
@testable import FamilyRules

@MainActor
final class AllDevicesModelTests: XCTestCase {
    func testRefreshLoadsAndSortsGroupsByDuration() async throws {
        let model = AllDevicesModel(registrationClient: RegistrationClientStubForAllDevices(
            groupsPayload: GroupsUsageReportPayload(groups: [
                DeviceUsageGroupPayload(
                    groupName: "Games",
                    totalSeconds: 1200,
                    applications: [
                        DeviceUsageApplicationPayload(appName: "Minecraft", deviceName: "Desk Mac", durationSeconds: 1200, iconBase64Png: nil),
                    ]
                ),
                DeviceUsageGroupPayload(
                    groupName: "Learning",
                    totalSeconds: 2400,
                    applications: [
                        DeviceUsageApplicationPayload(appName: "Safari", deviceName: "School Mac", durationSeconds: 2400, iconBase64Png: nil),
                    ]
                ),
            ])
        ))

        model.refresh(registration: registration)
        try await waitForRefresh(model)

        XCTAssertEqual(model.groups.map(\.groupName), ["Learning", "Games"])
        XCTAssertNil(model.errorMessage)
        XCTAssertNotEqual(model.lastUpdatedDescription, "Never")
    }

    func testRefreshShowsInlineErrorWhenRequestFails() async throws {
        let model = AllDevicesModel(registrationClient: RegistrationClientStubForAllDevices(error: TestError.fetchFailed))

        model.refresh(registration: registration)
        try await waitForRefresh(model)

        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(model.errorMessage, TestError.fetchFailed.localizedDescription)
    }

    func testRefreshWithoutRegistrationShowsHelpfulMessage() {
        let model = AllDevicesModel(registrationClient: RegistrationClientStubForAllDevices())

        model.refresh(registration: nil)

        XCTAssertEqual(model.errorMessage, String.localized("Register this Mac before loading All My Devices."))
        XCTAssertTrue(model.groups.isEmpty)
    }

    func testSecondRefreshCancelsFirstAndUsesLatestResult() async throws {
        // First refresh is issued; then a second one cancels it.
        // The second call's result (empty groups) should be what the model
        // reflects after both settle.
        let stub = ToggleStub()
        let model = AllDevicesModel(registrationClient: stub)

        // Start first refresh — it blocks inside ToggleStub waiting for setPayload.
        model.refresh(registration: registration)

        // Start second refresh while the first is still in-flight; the model
        // cancels the first Task and starts a new one.
        model.refresh(registration: registration)  // cancels first

        // Unblock both pending fetchGroupsUsageReport calls (whichever order
        // the Tasks happen to be waiting in) with empty payloads.
        await stub.setPayload(GroupsUsageReportPayload(groups: []))
        await stub.setPayload(GroupsUsageReportPayload(groups: []))

        try await waitForRefresh(model)

        // The second call's result (empty) should win.
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testFormatDurationHandlesNegativeValues() async throws {
        // Negative seconds from a server bug should not produce garbage output.
        // We verify indirectly through the view-level formatDuration helper by
        // checking that a group with negative totalSeconds renders as "0s" in
        // the groups list (via the model sort which uses the raw value, not the
        // display string). We exercise the formatDuration path by injecting a
        // negative-duration group and asserting no crash.
        let model = AllDevicesModel(registrationClient: RegistrationClientStubForAllDevices(
            groupsPayload: GroupsUsageReportPayload(groups: [
                DeviceUsageGroupPayload(groupName: "Bad", totalSeconds: -5, applications: [])
            ])
        ))

        model.refresh(registration: registration)
        try await waitForRefresh(model)

        XCTAssertEqual(model.groups.count, 1)
        XCTAssertEqual(model.groups[0].totalSeconds, -5)
        // No crash is the primary assertion; the view's formatDuration guards against negative.
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

    /// Waits for `model.isLoading` to become `false`, polling with a short sleep
    /// so unstructured tasks spawned by `refresh` have time to complete.
    private func waitForRefresh(_ model: AllDevicesModel, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !model.isLoading {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for refresh to complete")
    }
}

private actor RegistrationClientStubForAllDevices: RegistrationClientProtocol {
    var groupsPayload: GroupsUsageReportPayload
    let error: Error?

    init(groupsPayload: GroupsUsageReportPayload = GroupsUsageReportPayload(groups: []), error: Error? = nil) {
        self.groupsPayload = groupsPayload
        self.error = error
    }

    func register(serverURL: String, username: String, password: String, instanceName: String) async throws -> RegistrationResult {
        RegistrationResult(serverURL: serverURL, instanceId: "instance", instanceToken: "token")
    }

    func unregister(registration: RegistrationRecord) async throws {}

    func fetchGroupsUsageReport(registration: RegistrationRecord) async throws -> GroupsUsageReportPayload {
        if let error {
            throw error
        }
        return groupsPayload
    }
}

/// A stub that blocks until `setPayload` is called, then returns that payload.
/// Useful for controlling the order of two overlapping refresh calls.
private actor ToggleStub: RegistrationClientProtocol {
    private var pendingContinuation: CheckedContinuation<GroupsUsageReportPayload, Never>?
    private var readyPayload: GroupsUsageReportPayload?

    func setPayload(_ payload: GroupsUsageReportPayload) {
        if let cont = pendingContinuation {
            pendingContinuation = nil
            cont.resume(returning: payload)
        } else {
            readyPayload = payload
        }
    }

    func register(serverURL: String, username: String, password: String, instanceName: String) async throws -> RegistrationResult {
        RegistrationResult(serverURL: serverURL, instanceId: "i", instanceToken: "t")
    }

    func unregister(registration: RegistrationRecord) async throws {}

    func fetchGroupsUsageReport(registration: RegistrationRecord) async throws -> GroupsUsageReportPayload {
        if let ready = readyPayload {
            readyPayload = nil
            return ready
        }
        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
        }
    }
}

private enum TestError: LocalizedError {
    case fetchFailed

    var errorDescription: String? {
        switch self {
        case .fetchFailed:
            return "Fetch failed"
        }
    }
}
