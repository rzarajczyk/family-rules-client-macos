import AppKit
import Darwin

enum SessionActionExecutor {
    static func execute(_ action: HelperDeviceAction) throws -> String? {
        switch action {
        case .lockScreen:
            try requestScreenLockViaLoginFramework(actionName: "LOCK_SCREEN")
            return "Lock requested"
        case .switchUser:
            try requestScreenLockViaLoginFramework(actionName: "SWITCH_USER")
            return "Switch user requested"
        case .logout, .terminateApp:
            return nil
        }
    }

    private static func requestScreenLockViaLoginFramework(actionName: String) throws {
        let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        DiagnosticsLogger.record("App action \(actionName) starting private framework call on mainThread=\(Thread.isMainThread): \(frameworkPath) SACLockScreenImmediate")

        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            let message = dlerror().map { String(cString: $0) } ?? "Unknown dlopen error"
            DiagnosticsLogger.record("App action \(actionName) dlopen failed: \(message)")
            throw SessionActionError.custom("Failed to open login.framework: \(message)")
        }
        defer { dlclose(handle) }

        typealias LockFunction = @convention(c) () -> Void
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            let message = dlerror().map { String(cString: $0) } ?? "Unknown dlsym error"
            DiagnosticsLogger.record("App action \(actionName) dlsym failed: \(message)")
            throw SessionActionError.custom("Failed to resolve SACLockScreenImmediate: \(message)")
        }

        let lockScreen = unsafeBitCast(symbol, to: LockFunction.self)
        lockScreen()
        DiagnosticsLogger.record("App action \(actionName) private framework call completed")
    }
}

private enum SessionActionError: LocalizedError {
    case custom(String)

    var errorDescription: String? {
        switch self {
        case let .custom(message):
            return message
        }
    }
}
