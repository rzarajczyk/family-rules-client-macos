import Foundation

final class HelperXPCClient {
    /// Sends a ping to the XPC helper and returns the reply.
    /// Always safe to call from any isolation context; the underlying XPC
    /// reply is bridged through a checked continuation.
    func ping() async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(serviceName: HelperXPC.serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: FamilyRulesHelperXPCProtocol.self)

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
}

enum XPCClientError: LocalizedError {
    case invalidProxy
    case interrupted
    case invalidated

    var errorDescription: String? {
        switch self {
        case .invalidProxy:
            return "The helper proxy could not be created."
        case .interrupted:
            return "The helper connection was interrupted."
        case .invalidated:
            return "The helper connection was invalidated."
        }
    }
}
