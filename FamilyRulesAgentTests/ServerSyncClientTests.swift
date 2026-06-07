import XCTest
@testable import FamilyRules

final class ServerSyncClientTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(ServerSyncMockURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(ServerSyncMockURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        ServerSyncMockURLProtocol.handler = nil
    }

    func testSendClientInfoUsesExpectedEndpointHeadersAndBody() async throws {
        let client = ServerSyncClient(session: makeSession())

        ServerSyncMockURLProtocol.handler = { request in
            try requireEqual(request.url?.absoluteString, "https://example.com/api/v2/client-info")
            try requireEqual(request.httpMethod, "POST")
            try requireEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            try requireEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic aW5zdGFuY2UtMTp0b2tlbi0x")

            let body = try readBody(from: request)
            let payload = try decodeJSON(body)
            try requireEqual(payload["version"] as? String, "1.0.0")
            try requireEqual(payload["reportIntervalSeconds"] as? Int, 30)

            let knownApps = try requireValue(payload["knownApps"] as? [String: Any], "Missing knownApps payload")
            let finder = try requireValue(knownApps["com.apple.finder"] as? [String: Any], "Missing Finder payload")
            try requireEqual(finder["appName"] as? String, "Finder")

            let response = HTTPURLResponse(url: try requireValue(request.url, "Missing request URL"), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"status":"ok"}"#.utf8))
        }

        try await client.sendClientInfo(
            ClientInfoPayload(
                version: "1.0.0",
                availableStates: [
                    AvailableStatePayload(deviceState: "ACTIVE", title: "Active", icon: nil, description: nil, arguments: nil),
                ],
                timezoneOffsetSeconds: 0,
                reportIntervalSeconds: 30,
                knownApps: [
                    "com.apple.finder": KnownAppPayload(appName: "Finder", iconBase64Png: nil),
                ],
                capabilities: []
            ),
            registration: registration
        )
    }

    func testSendReportUsesExpectedEndpointAndParsesResponse() async throws {
        let client = ServerSyncClient(session: makeSession())

        ServerSyncMockURLProtocol.handler = { request in
            try requireEqual(request.url?.absoluteString, "https://example.com/api/v2/report")
            try requireEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic aW5zdGFuY2UtMTp0b2tlbi0x")

            let body = try readBody(from: request)
            let payload = try decodeJSON(body)
            try requireEqual(payload["screenTime"] as? Int, 45)

            let applications = try requireValue(payload["applications"] as? [String: Any], "Missing applications payload")
            try requireEqual(applications["com.apple.finder"] as? Int, 45)

            let activeApps = try requireValue(payload["activeApps"] as? [String], "Missing activeApps payload")
            try requireEqual(activeApps, ["com.apple.finder"])
            try requireEqual(payload["mediaPlayingApps"] as? [String], [])

            let response = HTTPURLResponse(url: try requireValue(request.url, "Missing request URL"), statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data(#"{"deviceState":"ACTIVE","extra":null,"serverCommands":[]}"#.utf8)
            return (response, data)
        }

        let response = try await client.sendReport(
            ReportPayload(
                screenTime: 45,
                applications: ["com.apple.finder": 45],
                activeApps: ["com.apple.finder"]
            ),
            registration: registration
        )

        XCTAssertEqual(response.deviceState, "ACTIVE")
        XCTAssertTrue(response.serverCommands.isEmpty)
    }

    func testSendCommandAcksUsesExpectedEndpointAndBody() async throws {
        let client = ServerSyncClient(session: makeSession())

        ServerSyncMockURLProtocol.handler = { request in
            try requireEqual(request.url?.absoluteString, "https://example.com/api/v2/command-acks")
            try requireEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic aW5zdGFuY2UtMTp0b2tlbi0x")

            let body = try readBody(from: request)
            let payload = try JSONDecoder().decode(CommandAcksUploadPayload.self, from: Data(body.utf8))
            try requireEqual(payload.commandAcks.count, 1)
            try requireEqual(payload.commandAcks.first?.commandId, "cmd-1")
            try requireEqual(payload.commandAcks.first?.commandName, "SEND_LOGS")

            let response = HTTPURLResponse(url: try requireValue(request.url, "Missing request URL"), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"status":"ok"}"#.utf8))
        }

        try await client.sendCommandAcks(
            CommandAcksUploadPayload(
                commandAcks: [
                    CommandAckUploadEntryPayload(
                        commandId: "cmd-1",
                        commandName: "SEND_LOGS",
                        protocolVersion: 1,
                        acknowledgedAt: "2026-05-09T10:00:00Z"
                    ),
                ]
            ),
            registration: registration
        )
    }

    func testSendCommandResultsUsesExpectedEndpointAndBody() async throws {
        let client = ServerSyncClient(session: makeSession())

        ServerSyncMockURLProtocol.handler = { request in
            try requireEqual(request.url?.absoluteString, "https://example.com/api/v2/command-results")
            try requireEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic aW5zdGFuY2UtMTp0b2tlbi0x")

            let body = try readBody(from: request)
            let payload = try JSONDecoder().decode(CommandResultsUploadPayload.self, from: Data(body.utf8))
            try requireEqual(payload.commandResults.count, 1)
            try requireEqual(payload.commandResults.first?.commandId, "cmd-1")
            try requireEqual(payload.commandResults.first?.status, "COMPLETED")
            try requireEqual(payload.commandResults.first?.details["lineCount"], "2")

            let response = HTTPURLResponse(url: try requireValue(request.url, "Missing request URL"), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"status":"ok"}"#.utf8))
        }

        try await client.sendCommandResults(
            CommandResultsUploadPayload(
                commandResults: [
                    CommandResultUploadEntryPayload(
                        commandId: "cmd-1",
                        commandName: "SEND_LOGS",
                        protocolVersion: 1,
                        completedAt: "2026-05-09T10:01:00Z",
                        status: "COMPLETED",
                        message: "Uploaded logs.",
                        details: ["lineCount": "2", "logs": "line 1\nline 2"]
                    ),
                ]
            ),
            registration: registration
        )
    }

    func testFetchBlockedPlaybackAppsUsesExpectedEndpointAndParsesResponse() async throws {
        let client = ServerSyncClient(session: makeSession())

        ServerSyncMockURLProtocol.handler = { request in
            try requireEqual(request.url?.absoluteString, "https://example.com/api/v2/get-blocked-playback-apps")
            try requireEqual(request.httpMethod, "POST")
            try requireEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic aW5zdGFuY2UtMTp0b2tlbi0x")

            let response = HTTPURLResponse(url: try requireValue(request.url, "Missing request URL"), statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data(#"{"apps":[{"appPath":"com.microsoft.edgemac","appName":"Microsoft Edge"}]}"#.utf8)
            return (response, data)
        }

        let apps = try await client.fetchBlockedPlaybackApps(registration: registration)

        XCTAssertEqual(apps, [BlockedAppPayload(appPath: "com.microsoft.edgemac", appName: "Microsoft Edge")])
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerSyncMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private var registration: RegistrationRecord {
        RegistrationRecord(
            serverURL: "https://example.com/",
            username: "parent",
            instanceId: "instance-1",
            instanceToken: "token-1",
            instanceName: "Desk Mac"
        )
    }
}

private final class ServerSyncMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = ServerSyncMockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "ServerSyncMockURLProtocol", code: 0))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func readBody(from request: URLRequest) throws -> String {
    if let data = request.httpBody {
        return String(decoding: data, as: UTF8.self)
    }

    guard let stream = request.httpBodyStream else {
        throw TestFailure("Missing request body")
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let readCount = stream.read(buffer, maxLength: bufferSize)
        guard readCount >= 0 else {
            throw stream.streamError ?? NSError(domain: "ServerSyncMockURLProtocol", code: 1)
        }

        if readCount == 0 {
            break
        }

        data.append(buffer, count: readCount)
    }

    return String(decoding: data, as: UTF8.self)
}

private func decodeJSON(_ string: String) throws -> [String: Any] {
    let data = Data(string.utf8)
    return try requireValue(JSONSerialization.jsonObject(with: data) as? [String: Any], "Invalid JSON object")
}

private struct TestFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private func requireEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String? = nil) throws {
    guard actual == expected else {
        throw TestFailure(message ?? "Expected \(expected), got \(actual)")
    }
}

private func requireValue<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw TestFailure(message)
    }
    return value
}
