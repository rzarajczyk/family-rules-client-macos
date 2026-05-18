import XCTest
@testable import FamilyRules

final class RegistrationClientTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.handler = nil
    }

    func testRegisterSendsExpectedRequestAndParsesSuccess() async throws {
        let session = makeSession()
        let client = RegistrationClient(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v2/register-instance")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic cGFyZW50OnNlY3JldA==")

            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data(#"{"status":"SUCCESS","instanceId":"uuid-1","token":"token-1"}"#.utf8)
            return (response, data)
        }

        let result = try await client.register(
            serverURL: "https://example.com/",
            username: "parent",
            password: "secret",
            instanceName: "Desk Mac"
        )

        XCTAssertEqual(result.serverURL, "https://example.com")
        XCTAssertEqual(result.instanceId, "uuid-1")
        XCTAssertEqual(result.instanceToken, "token-1")
    }

    func testRegisterMapsKnownServerErrors() async throws {
        let cases: [(String, RegistrationClientError)] = [
            (#"{"status":"INVALID_PASSWORD"}"#, .invalidCredentials),
            (#"{"status":"INSTANCE_ALREADY_EXISTS"}"#, .instanceAlreadyExists),
            (#"{"status":"ILLEGAL_INSTANCE_NAME"}"#, .illegalInstanceName),
        ]

        for (payload, expectedError) in cases {
            let session = makeSession()
            let client = RegistrationClient(session: session)

            MockURLProtocol.handler = { request in
                let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data(payload.utf8))
            }

            do {
                _ = try await client.register(
                    serverURL: "https://example.com",
                    username: "parent",
                    password: "secret",
                    instanceName: "Desk Mac"
                )
                XCTFail("Expected \(expectedError)")
            } catch let error as RegistrationClientError {
                XCTAssertEqual(error, expectedError)
            }
        }
    }

    func testRegisterRejectsInvalidServerURLBeforeRequest() async throws {
        let client = RegistrationClient(session: makeSession())

        do {
            _ = try await client.register(
                serverURL: "example.com",
                username: "parent",
                password: "secret",
                instanceName: "Desk Mac"
            )
            XCTFail("Expected invalid URL error")
        } catch let error as RegistrationClientError {
            XCTAssertEqual(error, .invalidServerURL)
        }
    }

    func testUnregisterUsesExpectedEndpointAndAuthorization() async throws {
        let client = RegistrationClient(session: makeSession())

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v2/unregister-instance")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic aW5zdGFuY2UtMTp0b2tlbi0x")

            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data(#"{"status":"SUCCESS"}"#.utf8)
            return (response, data)
        }

        try await client.unregister(registration: registration)
    }

    func testRegisterRejectsNonHttpScheme() async throws {
        let client = RegistrationClient(session: makeSession())

        do {
            _ = try await client.register(
                serverURL: "ftp://example.com",
                username: "parent",
                password: "secret",
                instanceName: "Desk Mac"
            )
            XCTFail("Expected invalid URL error")
        } catch let error as RegistrationClientError {
            XCTAssertEqual(error, .invalidServerURL)
        }
    }

    func testRegisterRejectsHttp500() async throws {
        let client = RegistrationClient(session: makeSession())

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await client.register(
                serverURL: "https://example.com",
                username: "parent",
                password: "secret",
                instanceName: "Desk Mac"
            )
            XCTFail("Expected requestFailed error")
        } catch let error as RegistrationClientError {
            XCTAssertEqual(error, .requestFailed(statusCode: 500))
        }
    }

    func testRegisterThrowsMalformedSuccessResponseWhenInstanceIdMissing() async throws {
        let client = RegistrationClient(session: makeSession())

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            // SUCCESS status but no instanceId or token fields.
            let data = Data(#"{"status":"SUCCESS"}"#.utf8)
            return (response, data)
        }

        do {
            _ = try await client.register(
                serverURL: "https://example.com",
                username: "parent",
                password: "secret",
                instanceName: "Desk Mac"
            )
            XCTFail("Expected malformedSuccessResponse error")
        } catch let error as RegistrationClientError {
            XCTAssertEqual(error, .malformedSuccessResponse)
        }
    }

    func testRegisterRejectsMissingServerURL() async throws {
        let client = RegistrationClient(session: makeSession())

        do {
            _ = try await client.register(
                serverURL: "",
                username: "parent",
                password: "secret",
                instanceName: "Desk Mac"
            )
            XCTFail("Expected missingServerURL error")
        } catch let error as RegistrationClientError {
            XCTAssertEqual(error, .missingServerURL)
        }
    }

    func testUnregisterRejectsNon200Response() async throws {
        let client = RegistrationClient(session: makeSession())

        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            try await client.unregister(registration: registration)
            XCTFail("Expected requestFailed error")
        } catch let error as RegistrationClientError {
            XCTAssertEqual(error, .requestFailed(statusCode: 403))
        }
    }


    func testFetchGroupsUsageReportParsesGroupsAndAppFallbackKeys() async throws {
        let client = RegistrationClient(session: makeSession())

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v2/groups-usage-report")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic aW5zdGFuY2UtMTp0b2tlbi0x")

            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data(#"{"groups":[{"groupName":"Social","totalTimeSeconds":3600,"memberApps":[{"name":"Discord","instanceName":"Desk Mac","duration":1800,"icon":"aWNvbg=="}]}]}"#.utf8)
            return (response, data)
        }

        let payload = try await client.fetchGroupsUsageReport(registration: registration)

        XCTAssertEqual(payload.groups.count, 1)
        XCTAssertEqual(payload.groups.first?.groupName, "Social")
        XCTAssertEqual(payload.groups.first?.totalSeconds, 3600)
        XCTAssertEqual(payload.groups.first?.applications.first?.appName, "Discord")
        XCTAssertEqual(payload.groups.first?.applications.first?.deviceName, "Desk Mac")
        XCTAssertEqual(payload.groups.first?.applications.first?.durationSeconds, 1800)
        XCTAssertEqual(payload.groups.first?.applications.first?.iconBase64Png, "aWNvbg==")
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private var registration: RegistrationRecord {
        RegistrationRecord(
            serverURL: "https://example.com",
            username: "parent",
            instanceId: "instance-1",
            instanceToken: "token-1",
            instanceName: "Desk Mac"
        )
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: 0))
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
