import Foundation

protocol RegistrationClientProtocol: Actor {
    func register(
        serverURL: String,
        username: String,
        password: String,
        instanceName: String
    ) async throws -> RegistrationResult
}

actor RegistrationClient {
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func register(
        serverURL: String,
        username: String,
        password: String,
        instanceName: String
    ) async throws -> RegistrationResult {
        let normalizedServerURL = try normalizeServerURL(serverURL)
        let endpoint = try registerURL(from: normalizedServerURL)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(basicAuthorization(username: username, password: password), forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(RegisterInstanceRequest(instanceName: instanceName, clientType: "MACOS_NATIVE"))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RegistrationClientError.invalidServerResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw RegistrationClientError.requestFailed(statusCode: httpResponse.statusCode)
        }

        let payload = try decoder.decode(RegisterInstanceResponse.self, from: data)

        switch payload.status {
        case .success:
            guard let instanceId = payload.instanceId, let token = payload.token else {
                throw RegistrationClientError.malformedSuccessResponse
            }

            return RegistrationResult(
                serverURL: normalizedServerURL,
                instanceId: instanceId,
                instanceToken: token
            )
        case .instanceAlreadyExists:
            throw RegistrationClientError.instanceAlreadyExists
        case .illegalInstanceName:
            throw RegistrationClientError.illegalInstanceName
        case .invalidPassword:
            throw RegistrationClientError.invalidCredentials
        }
    }

    private func normalizeServerURL(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RegistrationClientError.missingServerURL
        }

        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard URL(string: normalized)?.scheme != nil else {
            throw RegistrationClientError.invalidServerURL
        }

        return normalized
    }

    private func registerURL(from serverURL: String) throws -> URL {
        guard let baseURL = URL(string: serverURL) else {
            throw RegistrationClientError.invalidServerURL
        }

        return baseURL.appending(path: "api").appending(path: "v2").appending(path: "register-instance")
    }

    private func basicAuthorization(username: String, password: String) -> String {
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}

extension RegistrationClient: RegistrationClientProtocol {}

struct RegistrationResult {
    let serverURL: String
    let instanceId: String
    let instanceToken: String
}

private struct RegisterInstanceRequest: Encodable {
    let instanceName: String
    let clientType: String
}

private struct RegisterInstanceResponse: Decodable {
    let status: RegisterInstanceStatus
    let instanceId: String?
    let token: String?
}

private enum RegisterInstanceStatus: String, Decodable {
    case success = "SUCCESS"
    case instanceAlreadyExists = "INSTANCE_ALREADY_EXISTS"
    case illegalInstanceName = "ILLEGAL_INSTANCE_NAME"
    case invalidPassword = "INVALID_PASSWORD"
}

enum RegistrationClientError: LocalizedError, Equatable {
    case missingServerURL
    case invalidServerURL
    case invalidServerResponse
    case malformedSuccessResponse
    case invalidCredentials
    case instanceAlreadyExists
    case illegalInstanceName
    case requestFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingServerURL:
            return "Enter a server URL."
        case .invalidServerURL:
            return "Enter a valid server URL, including http:// or https://."
        case .invalidServerResponse:
            return "The server returned an invalid response."
        case .malformedSuccessResponse:
            return "The server reported success but did not return instance credentials."
        case .invalidCredentials:
            return "The username or password is invalid."
        case .instanceAlreadyExists:
            return "A device with this instance name already exists for that user."
        case .illegalInstanceName:
            return "The instance name is invalid. Use at least 3 characters."
        case let .requestFailed(statusCode):
            return "The server returned HTTP \(statusCode)."
        }
    }
}
