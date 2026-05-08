import Foundation

final class HelperDelegate: NSObject, NSXPCListenerDelegate, FamilyRulesHelperXPCProtocol {
    private let listener = NSXPCListener.service()
    private let dateFormatter = ISO8601DateFormatter()

    func run() {
        listener.delegate = self
        listener.resume()
        RunLoop.current.run()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: FamilyRulesHelperXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func ping(_ reply: @escaping (String) -> Void) {
        reply("pong from helper at \(dateFormatter.string(from: Date()))")
    }
}

HelperDelegate().run()
