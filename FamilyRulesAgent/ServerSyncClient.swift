import Foundation

protocol ServerSyncClientProtocol: Actor {
    func sendClientInfo(_ payload: ClientInfoPayload, registration: RegistrationRecord) async throws
    func sendReport(_ payload: ReportPayload, registration: RegistrationRecord) async throws -> ReportResponsePayload
}

actor ServerSyncClient {
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func sendClientInfo(_ payload: ClientInfoPayload, registration: RegistrationRecord) async throws {
        let endpoint = try endpointURL(serverURL: registration.serverURL, path: "client-info")
        var request = authorizedRequest(url: endpoint, registration: registration)
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validate(response: response)
        guard httpResponse.statusCode == 200 else {
            throw ServerSyncClientError.requestFailed(statusCode: httpResponse.statusCode)
        }

        _ = try decoder.decode(ClientInfoResponsePayload.self, from: data)
    }

    func sendReport(_ payload: ReportPayload, registration: RegistrationRecord) async throws -> ReportResponsePayload {
        let endpoint = try endpointURL(serverURL: registration.serverURL, path: "report")
        var request = authorizedRequest(url: endpoint, registration: registration)
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validate(response: response)
        guard httpResponse.statusCode == 200 else {
            throw ServerSyncClientError.requestFailed(statusCode: httpResponse.statusCode)
        }

        return try decoder.decode(ReportResponsePayload.self, from: data)
    }

    private func authorizedRequest(url: URL, registration: RegistrationRecord) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(basicAuthorization(username: registration.instanceId, password: registration.instanceToken), forHTTPHeaderField: "Authorization")
        return request
    }

    private func endpointURL(serverURL: String, path: String) throws -> URL {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed

        guard !normalized.isEmpty, let baseURL = URL(string: normalized), baseURL.scheme != nil else {
            throw ServerSyncClientError.invalidServerURL
        }

        return baseURL.appending(path: "api").appending(path: "v2").appending(path: path)
    }

    private func validate(response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServerSyncClientError.invalidServerResponse
        }

        return httpResponse
    }

    private func basicAuthorization(username: String, password: String) -> String {
        let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}

extension ServerSyncClient: ServerSyncClientProtocol {}

struct ClientInfoPayload: Encodable, Equatable {
    let version: String
    let availableStates: [AvailableStatePayload]
    let timezoneOffsetSeconds: Int
    let reportIntervalSeconds: Int
    let knownApps: [String: KnownAppPayload]
    let supportedServerCommands: [String]
}

struct AvailableStatePayload: Encodable, Equatable {
    let deviceState: String
    let title: String
    let icon: String?
    let description: String?
    let arguments: Set<String>?
}

struct KnownAppPayload: Encodable, Equatable {
    let appName: String
    let iconBase64Png: String?
}

struct ReportPayload: Encodable, Equatable {
    let screenTime: Int
    let applications: [String: Int]
    let activeApps: Set<String>
}

private struct ClientInfoResponsePayload: Decodable {
    let status: String
}

struct ReportResponsePayload: Decodable, Equatable {
    let deviceState: String
    let extra: String?
    let serverCommands: [ServerCommandPayload]
}

struct ServerCommandPayload: Decodable, Equatable {
    let commandId: String
    let commandName: String
    let issuedAt: String
    let protocolVersion: Int
}

enum ServerSyncClientError: LocalizedError, Equatable {
    case invalidServerURL
    case invalidServerResponse
    case requestFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter a valid server URL, including http:// or https://."
        case .invalidServerResponse:
            return "The server returned an invalid response."
        case let .requestFailed(statusCode):
            return "The server returned HTTP \(statusCode)."
        }
    }
}
