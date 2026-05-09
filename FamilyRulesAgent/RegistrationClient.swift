import Foundation

protocol RegistrationClientProtocol: Actor {
    func register(
        serverURL: String,
        username: String,
        password: String,
        instanceName: String
    ) async throws -> RegistrationResult
    func unregister(registration: RegistrationRecord) async throws
    func fetchGroupsUsageReport(registration: RegistrationRecord) async throws -> GroupsUsageReportPayload
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

        guard (200..<300).contains(httpResponse.statusCode) else {
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

    func unregister(registration: RegistrationRecord) async throws {
        let endpoint = try endpointURL(serverURL: registration.serverURL, path: "unregister-instance")
        var request = authorizedRequest(url: endpoint, username: registration.instanceId, password: registration.instanceToken)
        request.httpBody = try encoder.encode(EmptyRequestBody())

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RegistrationClientError.invalidServerResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RegistrationClientError.requestFailed(statusCode: httpResponse.statusCode)
        }

        let payload = try decoder.decode(StatusResponse.self, from: data)
        guard payload.status == "SUCCESS" else {
            throw RegistrationClientError.requestFailed(statusCode: httpResponse.statusCode)
        }
    }

    func fetchGroupsUsageReport(registration: RegistrationRecord) async throws -> GroupsUsageReportPayload {
        let endpoint = try endpointURL(serverURL: registration.serverURL, path: "groups-usage-report")
        var request = authorizedRequest(url: endpoint, username: registration.instanceId, password: registration.instanceToken)
        request.httpBody = try encoder.encode(EmptyRequestBody())

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RegistrationClientError.invalidServerResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RegistrationClientError.requestFailed(statusCode: httpResponse.statusCode)
        }

        return try decoder.decode(GroupsUsageReportPayload.self, from: data)
    }

    private func normalizeServerURL(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RegistrationClientError.missingServerURL
        }

        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let scheme = URL(string: normalized)?.scheme,
              scheme == "http" || scheme == "https" else {
            throw RegistrationClientError.invalidServerURL
        }

        return normalized
    }

    private func registerURL(from serverURL: String) throws -> URL {
        try endpointURL(serverURL: serverURL, path: "register-instance")
    }

    private func endpointURL(serverURL: String, path: String) throws -> URL {
        guard let baseURL = URL(string: serverURL) else {
            throw RegistrationClientError.invalidServerURL
        }

        return baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v2")
            .appendingPathComponent(path)
    }

    private func authorizedRequest(url: URL, username: String, password: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(basicAuthorization(username: username, password: password), forHTTPHeaderField: "Authorization")
        return request
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

struct GroupsUsageReportPayload: Decodable, Equatable {
    let groups: [DeviceUsageGroupPayload]
}

struct DeviceUsageGroupPayload: Decodable, Equatable {
    let groupName: String
    let totalSeconds: Int
    let applications: [DeviceUsageApplicationPayload]

    private enum CodingKeys: String, CodingKey {
        case groupName
        case totalSeconds
        case totalTimeSeconds
        case applications
        case memberApps
        case apps
    }

    init(groupName: String, totalSeconds: Int, applications: [DeviceUsageApplicationPayload]) {
        self.groupName = groupName
        self.totalSeconds = totalSeconds
        self.applications = applications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName) ?? "Unnamed Group"
        totalSeconds = try container.decodeIfPresent(Int.self, forKey: .totalSeconds)
            ?? container.decodeIfPresent(Int.self, forKey: .totalTimeSeconds)
            ?? 0
        applications = try container.decodeIfPresent([DeviceUsageApplicationPayload].self, forKey: .applications)
            ?? container.decodeIfPresent([DeviceUsageApplicationPayload].self, forKey: .memberApps)
            ?? container.decodeIfPresent([DeviceUsageApplicationPayload].self, forKey: .apps)
            ?? []
    }
}

struct DeviceUsageApplicationPayload: Decodable, Equatable {
    let appName: String
    let deviceName: String
    let durationSeconds: Int
    let iconBase64Png: String?

    private enum CodingKeys: String, CodingKey {
        case appName
        case name
        case deviceName
        case instanceName
        case durationSeconds
        case duration
        case usageDurationSeconds
        case iconBase64Png
        case icon
    }

    init(appName: String, deviceName: String, durationSeconds: Int, iconBase64Png: String?) {
        self.appName = appName
        self.deviceName = deviceName
        self.durationSeconds = durationSeconds
        self.iconBase64Png = iconBase64Png
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
            ?? container.decodeIfPresent(String.self, forKey: .name)
            ?? "Unknown App"
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
            ?? container.decodeIfPresent(String.self, forKey: .instanceName)
            ?? "Unknown Device"
        durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
            ?? container.decodeIfPresent(Int.self, forKey: .duration)
            ?? container.decodeIfPresent(Int.self, forKey: .usageDurationSeconds)
            ?? 0
        iconBase64Png = try container.decodeIfPresent(String.self, forKey: .iconBase64Png)
            ?? container.decodeIfPresent(String.self, forKey: .icon)
    }
}

private struct RegisterInstanceRequest: Encodable {
    let instanceName: String
    let clientType: String
}

private struct EmptyRequestBody: Encodable {}

private struct StatusResponse: Decodable {
    let status: String
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
