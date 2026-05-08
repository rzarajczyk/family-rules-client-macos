import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var registration: RegistrationRecord?
    @Published private(set) var startupErrorMessage: String?

    private let registrationStore: any RegistrationStoreProtocol
    private let registrationClient: any RegistrationClientProtocol

    init(
        registrationStore: any RegistrationStoreProtocol = RegistrationStore(),
        registrationClient: any RegistrationClientProtocol = RegistrationClient()
    ) {
        self.registrationStore = registrationStore
        self.registrationClient = registrationClient
        reloadRegistration()
    }

    var isRegistered: Bool {
        registration != nil
    }

    private func reloadRegistration() {
        do {
            registration = try registrationStore.loadRegistration()
            startupErrorMessage = nil
        } catch {
            registration = nil
            startupErrorMessage = error.localizedDescription
        }
    }

    func register(
        serverURL: String,
        username: String,
        password: String,
        instanceName: String
    ) async throws {
        let result = try await registrationClient.register(
            serverURL: serverURL,
            username: username,
            password: password,
            instanceName: instanceName
        )

        let record = RegistrationRecord(
            serverURL: result.serverURL,
            username: username,
            instanceId: result.instanceId,
            instanceToken: result.instanceToken,
            instanceName: instanceName
        )

        try registrationStore.saveRegistration(record)
        registration = record
        startupErrorMessage = nil
    }
}
