import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var registration: RegistrationRecord?
    @Published private(set) var startupErrorMessage: String?
    @Published private(set) var lastUninstallDescription = "Never"

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

    func unregisterAndClearLocalState(log: @escaping (String) -> Void) async -> RegistrationCleanupResult {
        guard let registration else {
            // No active registration — nothing to unregister or clean up.
            return RegistrationCleanupResult(serverErrorMessage: nil, localCleanupErrorMessage: "No registration found.")
        }

        var serverErrorMessage: String?

        do {
            try await registrationClient.unregister(registration: registration)
            log("Unregistered instance \(registration.instanceId) on server")
        } catch {
            serverErrorMessage = error.localizedDescription
            log("Failed to unregister instance \(registration.instanceId) on server: \(error.localizedDescription)")
        }

        do {
            try registrationStore.clearRegistration()
            self.registration = nil
            startupErrorMessage = nil
            lastUninstallDescription = timestamp()
            log("Cleared local registration state for \(registration.instanceName)")
            return RegistrationCleanupResult(serverErrorMessage: serverErrorMessage, localCleanupErrorMessage: nil)
        } catch {
            startupErrorMessage = error.localizedDescription
            log("Failed to clear local registration state: \(error.localizedDescription)")
            return RegistrationCleanupResult(serverErrorMessage: serverErrorMessage, localCleanupErrorMessage: error.localizedDescription)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    private func timestamp() -> String {
        AppModel.timeFormatter.string(from: Date())
    }
}

struct RegistrationCleanupResult: Equatable {
    let serverErrorMessage: String?
    let localCleanupErrorMessage: String?

    var summary: String {
        switch (serverErrorMessage, localCleanupErrorMessage) {
        case (nil, nil):
            return "This Mac was unregistered and local data was removed."
        case (nil, "No registration found."):
            return "This Mac was not registered."
        case let (serverError?, nil):
            return "Local data was removed, but server unregister failed: \(serverError)"
        case let (_, localError?):
            return "Local cleanup failed: \(localError)"
        }
    }
}
