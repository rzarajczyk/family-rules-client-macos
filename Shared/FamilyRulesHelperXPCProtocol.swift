import Foundation

@objc(FamilyRulesHelperXPCProtocol)
protocol FamilyRulesHelperXPCProtocol {
    func ping(_ reply: @escaping (String) -> Void)
    func updateAgentStatus(_ payload: Data, reply: @escaping (String) -> Void)
    func fetchLifecycleStatus(_ reply: @escaping (Data?, String?) -> Void)
    func executeDeviceAction(_ payload: Data, reply: @escaping (String?, String?) -> Void)
}

enum HelperXPC {
    static let serviceName = "com.familyrules.agent.helper"
}

struct HelperRegistrationPayload: Codable, Equatable, Sendable {
    let serverURL: String
    let username: String
    let instanceId: String
    let instanceToken: String
    let instanceName: String
}

struct AgentStatusPayload: Codable, Equatable, Sendable {
    let registration: HelperRegistrationPayload
    let agentBundleIdentifier: String
    let isAdminDisabled: Bool
    let lastObservedDeviceState: String
    let sentAt: Date
}

struct HelperLifecycleStatusPayload: Codable, Equatable, Sendable {
    let isAdminDisabled: Bool
    let lastHeartbeatAt: Date?
    let lastObservedDeviceState: String
    let lastPollDescription: String?
    let lastRelaunchDescription: String?
    let lastActionDescription: String?
}

enum HelperDeviceAction: String, Codable, Equatable, Sendable {
    case lockScreen = "LOCK_SCREEN"
    case logout = "LOGOUT"
    case switchUser = "SWITCH_USER"
    case terminateApp = "TERMINATE_APP"
}

struct HelperDeviceActionRequest: Codable, Equatable, Sendable {
    let action: HelperDeviceAction
    let targetIdentifier: String?
    let requestedAt: Date

    init(action: HelperDeviceAction, targetIdentifier: String? = nil, requestedAt: Date) {
        self.action = action
        self.targetIdentifier = targetIdentifier
        self.requestedAt = requestedAt
    }
}

struct StateCountdownPresentation: Equatable, Sendable {
    let title: String
    let message: String
    let secondsRemaining: Int
}

enum LifecycleStateBridge {
    static func normalize(_ rawValue: String) -> String {
        switch rawValue.uppercased() {
        case "APP_DISABLED", "ADMIN_DISABLED":
            return "ADMIN_DISABLED"
        case "LOCKED":
            return "LOCK_SCREEN"
        case "LOCKED_WITH_COUNTDOWN":
            return "LOCK_SCREEN_WITH_TIMEOUT"
        case "LOGGED_OUT":
            return "LOGOUT"
        case "LOGGED_OUT_WITH_COUNTDOWN":
            return "LOGOUT_WITH_TIMEOUT"
        default:
            return rawValue.uppercased()
        }
    }

    static func isAdminDisabled(_ rawValue: String) -> Bool {
        normalize(rawValue) == "ADMIN_DISABLED"
    }

    static func helperAction(for rawValue: String) -> HelperDeviceAction? {
        switch normalize(rawValue) {
        case "LOGOUT", "LOGOUT_WITH_TIMEOUT":
            return .switchUser
        default:
            return nil
        }
    }
}
