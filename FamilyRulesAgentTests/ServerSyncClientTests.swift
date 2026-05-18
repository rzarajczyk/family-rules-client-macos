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
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v2/client-info")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic aW5zdGFuY2UtMTp0b2tlbi0x")

            let body = try readBody(from: request)
            let payload = try decodeJSON(body)
            XCTAssertEqual(payload["version"] as? String, "1.0.0")
            XCTAssertEqual(payload["reportIntervalSeconds"] as? Int, 30)

            let knownApps = try XCTUnwrap(payload["knownApps"] as? [String: Any])
            let finder = try XCTUnwrap(knownApps["com.apple.finder"] as? [String: Any])
            XCTAssertEqual(finder["appName"] as? String, "Finder")

            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
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
                supportedServerCommands: []
            ),
            registration: registration
        )
    }

    func testSendReportUsesExpectedEndpointAndParsesResponse() async throws {
        let client = ServerSyncClient(session: makeSession())

        ServerSyncMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v2/report")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic aW5zdGFuY2UtMTp0b2tlbi0x")

            let body = try readBody(from: request)
            let payload = try decodeJSON(body)
            XCTAssertEqual(payload["screenTime"] as? Int, 45)

            let applications = try XCTUnwrap(payload["applications"] as? [String: Any])
            XCTAssertEqual(applications["com.apple.finder"] as? Int, 45)

            let activeApps = try XCTUnwrap(payload["activeApps"] as? [String])
            XCTAssertEqual(activeApps, ["com.apple.finder"])

            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
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
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v2/command-acks")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic aW5zdGFuY2UtMTp0b2tlbi0x")

            let body = try readBody(from: request)
            let payload = try JSONDecoder().decode(CommandAcksUploadPayload.self, from: Data(body.utf8))
            XCTAssertEqual(payload.commandAcks.count, 1)
            XCTAssertEqual(payload.commandAcks.first?.commandId, "cmd-1")
            XCTAssertEqual(payload.commandAcks.first?.commandName, "SEND_LOGS")

            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
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
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v2/command-results")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic aW5zdGFuY2UtMTp0b2tlbi0x")

            let body = try readBody(from: request)
            let payload = try JSONDecoder().decode(CommandResultsUploadPayload.self, from: Data(body.utf8))
            XCTAssertEqual(payload.commandResults.count, 1)
            XCTAssertEqual(payload.commandResults.first?.commandId, "cmd-1")
            XCTAssertEqual(payload.commandResults.first?.status, "COMPLETED")
            XCTAssertEqual(payload.commandResults.first?.details["lineCount"], "2")

            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
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
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v2/get-blocked-playback-apps")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic aW5zdGFuY2UtMTp0b2tlbi0x")

            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
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
        XCTFail("Missing request body")
        return ""
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
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
