import Foundation

@objc(FamilyRulesHelperXPCProtocol)
protocol FamilyRulesHelperXPCProtocol {
    func ping(_ reply: @escaping (String) -> Void)
}

enum HelperXPC {
    static let serviceName = "com.familyrules.agent.helper"
}
