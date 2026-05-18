import XCTest
@testable import FamilyRules

@MainActor
final class AppModelTests: XCTestCase {
    func testLoadsExistingRegistrationOnInit() async throws {
        let expected = RegistrationRecord(
            serverURL: "https://example.com",
            username: "parent",
            instanceId: "instance-1",
            instanceToken: "token-1",
            instanceName: "Child Mac"
        )

        let model = AppModel(
            registrationStore: RegistrationStoreStub(loadedRegistration: expected),
            registrationClient: RegistrationClientStub()
        )

        XCTAssertTrue(model.isRegistered)
        XCTAssertEqual(model.registration?.serverURL, expected.serverURL)
        XCTAssertEqual(model.registration?.username, expected.username)
        XCTAssertEqual(model.registration?.instanceId, expected.instanceId)
        XCTAssertNil(model.startupErrorMessage)
    }

    func testSetsStartupErrorWhenLoadingFails() async throws {
        let model = AppModel(
            registrationStore: RegistrationStoreStub(loadError: TestError.loadFailed),
            registrationClient: RegistrationClientStub()
        )

        XCTAssertFalse(model.isRegistered)
        XCTAssertEqual(model.startupErrorMessage, TestError.loadFailed.localizedDescription)
    }

    func testRegisterPersistsAndPublishesRegistration() async throws {
        let store = RegistrationStoreStub()
        let client = RegistrationClientStub(
            result: RegistrationResult(
                serverURL: "https://example.com",
                instanceId: "instance-2",
                instanceToken: "token-2"
            )
        )

        let model = AppModel(registrationStore: store, registrationClient: client)

        try await model.register(
            serverURL: "https://example.com/",
            username: "parent",
            password: "secret",
            instanceName: "Kitchen Mac"
        )

        XCTAssertTrue(model.isRegistered)
        XCTAssertEqual(model.registration?.serverURL, "https://example.com")
        XCTAssertEqual(model.registration?.instanceId, "instance-2")
        XCTAssertEqual(store.savedRegistration?.instanceToken, "token-2")
        XCTAssertNil(model.startupErrorMessage)
    }

    func testRegisterLeavesStateUnregisteredWhenSaveFails() async throws {
        let model = AppModel(
            registrationStore: RegistrationStoreStub(saveError: TestError.saveFailed),
            registrationClient: RegistrationClientStub(
                result: RegistrationResult(
                    serverURL: "https://example.com",
                    instanceId: "instance-3",
                    instanceToken: "token-3"
                )
            )
        )

        do {
            try await model.register(
                serverURL: "https://example.com",
                username: "parent",
                password: "secret",
                instanceName: "Desk Mac"
            )
            XCTFail("Expected save failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, TestError.saveFailed.localizedDescription)
        }

        XCTAssertFalse(model.isRegistered)
        XCTAssertNil(model.registration)
    }

    func testUnregisterClearsPublishedRegistrationWhenLocalCleanupSucceeds() async throws {
        let existing = RegistrationRecord(
            serverURL: "https://example.com",
            username: "parent",
            instanceId: "instance-4",
            instanceToken: "token-4",
            instanceName: "Desk Mac"
        )
        let store = RegistrationStoreStub(loadedRegistration: existing)
        let client = RegistrationClientStub()
        let model = AppModel(registrationStore: store, registrationClient: client)

        let result = await model.unregisterAndClearLocalState(log: { _ in })

        XCTAssertNil(result.serverErrorMessage)
        XCTAssertNil(result.localCleanupErrorMessage)
        XCTAssertFalse(model.isRegistered)
        XCTAssertNil(model.registration)
        XCTAssertTrue(store.didClearRegistration)
        let lastUnregistered = await client.lastUnregisteredRegistration()
        XCTAssertEqual(lastUnregistered?.instanceId, "instance-4")
    }

    func testUnregisterContinuesLocalCleanupWhenServerCallFails() async throws {
        let existing = RegistrationRecord(
            serverURL: "https://example.com",
            username: "parent",
            instanceId: "instance-5",
            instanceToken: "token-5",
            instanceName: "Kitchen Mac"
        )
        let store = RegistrationStoreStub(loadedRegistration: existing)
        let client = RegistrationClientStub(error: TestError.unregisterFailed)
        let model = AppModel(registrationStore: store, registrationClient: client)

        let result = await model.unregisterAndClearLocalState(log: { _ in })

        XCTAssertEqual(result.serverErrorMessage, TestError.unregisterFailed.localizedDescription)
        XCTAssertNil(result.localCleanupErrorMessage)
        XCTAssertFalse(model.isRegistered)
        XCTAssertTrue(store.didClearRegistration)
    }

    func testUnregisterWithNoRegistrationReturnsNotRegisteredSummary() async throws {
        let model = AppModel(
            registrationStore: RegistrationStoreStub(),
            registrationClient: RegistrationClientStub()
        )
        XCTAssertFalse(model.isRegistered)

        let result = await model.unregisterAndClearLocalState(log: { _ in })

        XCTAssertNil(result.serverErrorMessage)
        XCTAssertEqual(result.localCleanupErrorMessage, "No registration found.")
        XCTAssertEqual(result.summary, "This Mac was not registered.")
        XCTAssertFalse(model.isRegistered)
    }

    func testUnregisterUpdatesLastUninstallDescription() async throws {
        let existing = RegistrationRecord(
            serverURL: "https://example.com",
            username: "parent",
            instanceId: "instance-7",
            instanceToken: "token-7",
            instanceName: "Living Room Mac"
        )
        let store = RegistrationStoreStub(loadedRegistration: existing)
        let model = AppModel(registrationStore: store, registrationClient: RegistrationClientStub())

        XCTAssertEqual(model.lastUninstallDescription, "Never")

        _ = await model.unregisterAndClearLocalState(log: { _ in })

        XCTAssertNotEqual(model.lastUninstallDescription, "Never")
    }


    func testUnregisterPreservesRegistrationWhenLocalCleanupFails() async throws {
        let existing = RegistrationRecord(
            serverURL: "https://example.com",
            username: "parent",
            instanceId: "instance-6",
            instanceToken: "token-6",
            instanceName: "Bedroom Mac"
        )
        let store = RegistrationStoreStub(loadedRegistration: existing, clearError: TestError.clearFailed)
        let model = AppModel(registrationStore: store, registrationClient: RegistrationClientStub())

        let result = await model.unregisterAndClearLocalState(log: { _ in })

        XCTAssertNil(result.serverErrorMessage)
        XCTAssertEqual(result.localCleanupErrorMessage, TestError.clearFailed.localizedDescription)
        XCTAssertTrue(model.isRegistered)
        XCTAssertEqual(model.registration?.instanceId, "instance-6")
    }
}

private final class RegistrationStoreStub: RegistrationStoreProtocol {
    var loadedRegistration: RegistrationRecord?
    var loadError: Error?
    var saveError: Error?
    var clearError: Error?

    private(set) var savedRegistration: RegistrationRecord?
    private(set) var didClearRegistration = false

    init(
        loadedRegistration: RegistrationRecord? = nil,
        loadError: Error? = nil,
        saveError: Error? = nil,
        clearError: Error? = nil
    ) {
        self.loadedRegistration = loadedRegistration
        self.loadError = loadError
        self.saveError = saveError
        self.clearError = clearError
    }

    func loadRegistration() throws -> RegistrationRecord? {
        if let loadError {
            throw loadError
        }

        return loadedRegistration
    }

    func saveRegistration(_ registration: RegistrationRecord) throws {
        if let saveError {
            throw saveError
        }

        savedRegistration = registration
    }

    func clearRegistration() throws {
        if let clearError {
            throw clearError
        }

        didClearRegistration = true
        loadedRegistration = nil
    }
}

private actor RegistrationClientStub: RegistrationClientProtocol {
    var result: RegistrationResult?
    var error: Error?
    private var lastUnregistered: RegistrationRecord?

    init(result: RegistrationResult? = nil, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func register(
        serverURL: String,
        username: String,
        password: String,
        instanceName: String
    ) async throws -> RegistrationResult {
        if let error {
            throw error
        }

        return result ?? RegistrationResult(
            serverURL: serverURL,
            instanceId: "instance-stub",
            instanceToken: "token-stub"
        )
    }

    func unregister(registration: RegistrationRecord) async throws {
        if let error {
            throw error
        }

        lastUnregistered = registration
    }

    func fetchGroupsUsageReport(registration: RegistrationRecord) async throws -> GroupsUsageReportPayload {
        GroupsUsageReportPayload(groups: [])
    }

    func lastUnregisteredRegistration() -> RegistrationRecord? {
        lastUnregistered
    }
}

private enum TestError: LocalizedError {
    case loadFailed
    case saveFailed
    case unregisterFailed
    case clearFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed:
            return "Load failed"
        case .saveFailed:
            return "Save failed"
        case .unregisterFailed:
            return "Unregister failed"
        case .clearFailed:
            return "Clear failed"
        }
    }
}
