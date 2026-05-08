import Foundation

final class HelperXPCClient {
    func ping(completion: @escaping (Result<String, Error>) -> Void) {
        let connection = NSXPCConnection(serviceName: HelperXPC.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: FamilyRulesHelperXPCProtocol.self)

        var didFinish = false
        let finish: (Result<String, Error>) -> Void = { result in
            guard !didFinish else { return }
            didFinish = true
            completion(result)
            connection.invalidate()
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
