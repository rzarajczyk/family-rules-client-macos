import XCTest
@testable import FamilyRulesAgent

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
}

private final class RegistrationStoreStub: RegistrationStoreProtocol {
    var loadedRegistration: RegistrationRecord?
    var loadError: Error?
    var saveError: Error?

    private(set) var savedRegistration: RegistrationRecord?

    init(
        loadedRegistration: RegistrationRecord? = nil,
        loadError: Error? = nil,
        saveError: Error? = nil
    ) {
        self.loadedRegistration = loadedRegistration
        self.loadError = loadError
        self.saveError = saveError
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
}

private actor RegistrationClientStub: RegistrationClientProtocol {
    var result: RegistrationResult?
    var error: Error?

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
}

private enum TestError: LocalizedError {
    case loadFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed:
            return "Load failed"
        case .saveFailed:
            return "Save failed"
        }
    }
}
