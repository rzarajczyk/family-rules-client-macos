import Foundation

protocol HelperLifecycleClientProtocol: AnyObject, Sendable {
    func ping() async throws -> String
    func updateAgentStatus(_ payload: AgentStatusPayload) async throws -> String
    func fetchLifecycleStatus() async throws -> HelperLifecycleStatusPayload
    func executeDeviceAction(_ request: HelperDeviceActionRequest) async throws -> String
}

final class HelperXPCClient: HelperLifecycleClientProtocol {
    /// Sends a ping to the XPC helper and returns the reply.
    /// Always safe to call from any isolation context; the underlying XPC
    /// reply is bridged through a checked continuation.
    func ping() async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let connection = configuredConnection()

            var didFinish = false
            let finish: (Result<String, Error>) -> Void = { result in
                guard !didFinish else { return }
                didFinish = true
                connection.invalidate()
                continuation.resume(with: result)
            }

            connection.interruptionHandler = {
                finish(.failure(XPCClientError.interrupted))
            }

            connection.invalidationHandler = {
                finish(.failure(XPCClientError.invalidated))
            }

            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                finish(.failure(error))
            }

            guard let helper = proxy as? FamilyRulesHelperXPCProtocol else {
                finish(.failure(XPCClientError.invalidProxy))
                return
            }

            helper.ping { reply in
                finish(.success(reply))
            }
        }
    }

    func updateAgentStatus(_ payload: AgentStatusPayload) async throws -> String {
        let encoded = try JSONEncoder().encode(payload)

        return try await withCheckedThrowingContinuation { continuation in
            let connection = configuredConnection()

            var didFinish = false
            let finish: (Result<String, Error>) -> Void = { result in
                guard !didFinish else { return }
                didFinish = true
                connection.invalidate()
                continuation.resume(with: result)
            }

            connection.interruptionHandler = {
                finish(.failure(XPCClientError.interrupted))
            }

            connection.invalidationHandler = {
                finish(.failure(XPCClientError.invalidated))
            }

            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                finish(.failure(error))
            }

            guard let helper = proxy as? FamilyRulesHelperXPCProtocol else {
                finish(.failure(XPCClientError.invalidProxy))
                return
            }

            helper.updateAgentStatus(encoded) { reply in
                if reply.hasPrefix("helper update failed:") {
                    finish(.failure(XPCClientError.remoteFailure(reply)))
                } else {
                    finish(.success(reply))
                }
            }
        }
    }

    func fetchLifecycleStatus() async throws -> HelperLifecycleStatusPayload {
        return try await withCheckedThrowingContinuation { continuation in
            let connection = configuredConnection()

            var didFinish = false
            let finish: (Result<HelperLifecycleStatusPayload, Error>) -> Void = { result in
                guard !didFinish else { return }
                didFinish = true
                connection.invalidate()
                continuation.resume(with: result)
            }

            connection.interruptionHandler = {
                finish(.failure(XPCClientError.interrupted))
            }

            connection.invalidationHandler = {
                finish(.failure(XPCClientError.invalidated))
            }

            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                finish(.failure(error))
            }

            guard let helper = proxy as? FamilyRulesHelperXPCProtocol else {
                finish(.failure(XPCClientError.invalidProxy))
                return
            }

            helper.fetchLifecycleStatus { data, errorMessage in
                if let errorMessage {
                    finish(.failure(XPCClientError.remoteFailure(errorMessage)))
                    return
                }

                guard let data else {
                    finish(.failure(XPCClientError.invalidReply))
                    return
                }

                do {
                    let payload = try JSONDecoder().decode(HelperLifecycleStatusPayload.self, from: data)
                    finish(.success(payload))
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }

    func executeDeviceAction(_ request: HelperDeviceActionRequest) async throws -> String {
        let encoded = try JSONEncoder().encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            let connection = configuredConnection()

            var didFinish = false
            let finish: (Result<String, Error>) -> Void = { result in
                guard !didFinish else { return }
                didFinish = true
                connection.invalidate()
                continuation.resume(with: result)
            }

            connection.interruptionHandler = {
                finish(.failure(XPCClientError.interrupted))
            }

            connection.invalidationHandler = {
                finish(.failure(XPCClientError.invalidated))
            }

            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                finish(.failure(error))
            }

            guard let helper = proxy as? FamilyRulesHelperXPCProtocol else {
                finish(.failure(XPCClientError.invalidProxy))
                return
            }

            helper.executeDeviceAction(encoded) { reply, errorMessage in
                if let errorMessage {
                    finish(.failure(XPCClientError.remoteFailure(errorMessage)))
                    return
                }

                guard let reply else {
                    finish(.failure(XPCClientError.invalidReply))
                    return
                }

                finish(.success(reply))
            }
        }
    }

    private func configuredConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: HelperXPC.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: FamilyRulesHelperXPCProtocol.self)
        return connection
    }
}

enum XPCClientError: LocalizedError {
    case invalidProxy
    case interrupted
    case invalidated
    case invalidReply
    case remoteFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidProxy:
            return "The helper proxy could not be created."
        case .interrupted:
            return "The helper connection was interrupted."
        case .invalidated:
            return "The helper connection was invalidated."
        case .invalidReply:
            return "The helper returned an invalid response."
        case let .remoteFailure(message):
            return message
        }
    }
}

extension XPCClientError {
    static func loggable(_ error: Error, context: String) -> Error {
        DiagnosticsLogger.record(error: error, context: context)
        return error
    }
}
