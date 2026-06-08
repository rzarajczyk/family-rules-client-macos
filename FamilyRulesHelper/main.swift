import AppKit
import Foundation
import Darwin

final class HelperDelegate: NSObject, NSXPCListenerDelegate, FamilyRulesHelperXPCProtocol, @unchecked Sendable {
    private let listener = NSXPCListener.service()
    private let dateFormatter = ISO8601DateFormatter()
    private let stateStore = HelperStateStore()
    private let playbackProbe = HelperMediaRemotePlaybackProbe()
    private let clock: () -> Date
    /// Serializes all mutable state access. XPC callbacks arrive on arbitrary
    /// threads; this queue ensures HelperStateStore is never touched concurrently.
    private let queue = DispatchQueue(label: "com.familyrules.helper.delegate")

    override init() {
        clock = Date.init
        super.init()
    }

    func run() {
        listener.delegate = self
        listener.resume()
        RunLoop.main.run()
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

    func updateAgentStatus(_ payload: Data, reply: @escaping (String) -> Void) {
        queue.async { [self] in
            do {
                let decoded = try JSONDecoder().decode(AgentStatusPayload.self, from: payload)
                stateStore.update(with: decoded)
                reply("helper updated at \(dateFormatter.string(from: clock()))")
            } catch {
                DiagnosticsLogger.record(error: error, context: "Helper failed to decode agent status")
                reply("helper update failed: \(error.localizedDescription)")
            }
        }
    }

    func fetchLifecycleStatus(_ reply: @escaping (Data?, String?) -> Void) {
        queue.async { [self] in
            do {
                let payload = stateStore.statusPayload()
                let data = try JSONEncoder().encode(payload)
                reply(data, nil)
            } catch {
                DiagnosticsLogger.record(error: error, context: "Helper failed to encode lifecycle status")
                reply(nil, error.localizedDescription)
            }
        }
    }

    func fetchPlaybackSnapshot(_ reply: @escaping (Data?, String?) -> Void) {
        DiagnosticsLogger.record("Helper fetchPlaybackSnapshot entry")
        queue.async { [self] in
            do {
                DiagnosticsLogger.record("Helper fetchPlaybackSnapshot called")
                let payload = playbackProbe.snapshot().map {
                    HelperPlaybackSnapshotPayload(
                        identifier: $0.identifier,
                        name: $0.name,
                        pid: $0.pid,
                        isPlaying: $0.isPlaying
                    )
                }
                DiagnosticsLogger.record("Helper fetchPlaybackSnapshot result: \(payload.map { $0.identifier } ?? "nil")")
                let data = try payload.map { try JSONEncoder().encode($0) }
                reply(data, nil)
            } catch {
                DiagnosticsLogger.record(error: error, context: "Helper failed to fetch playback snapshot")
                reply(nil, error.localizedDescription)
            }
        }
    }

    func executeDeviceAction(_ payload: Data, reply: @escaping (String?, String?) -> Void) {
        queue.async { [self] in
            do {
                let request = try JSONDecoder().decode(HelperDeviceActionRequest.self, from: payload)
                let result = try performDeviceAction(request.action, targetIdentifier: request.targetIdentifier)
                stateStore.recordAction(result, at: clock())
                reply(result, nil)
            } catch {
                DiagnosticsLogger.record(error: error, context: "Helper failed to execute device action")
                reply(nil, error.localizedDescription)
            }
        }
    }

    // Must be called on `queue`.
    private func performDeviceAction(_ action: HelperDeviceAction, targetIdentifier: String?) throws -> String {
        switch action {
        case .lockScreen:
            try requestScreenLockViaLoginFramework(actionName: "LOCK_SCREEN")
            return "Lock requested"
        case .logout:
            try runLoggedCommand(
                actionName: "LOGOUT",
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", "tell application \"System Events\" to log out"]
            )
            return "Logout requested"
        case .switchUser:
            // Match the legacy macOS client behavior: force the current session
            // into the lock/login UI instead of relying on fragile loginwindow CLI args.
            try requestScreenLockViaLoginFramework(actionName: "SWITCH_USER")
            return "Switch user requested"
        case .terminateApp:
            guard let targetIdentifier, !targetIdentifier.isEmpty else {
                throw HelperActionError.missingTargetIdentifier
            }

            let matches = NSRunningApplication.runningApplications(withBundleIdentifier: targetIdentifier)
            guard !matches.isEmpty else {
                throw HelperActionError.targetNotRunning(targetIdentifier)
            }

            for application in matches {
                application.forceTerminate()
            }

            return "Terminate requested for \(targetIdentifier)"
        }
    }

    private func requestScreenLockViaLoginFramework(actionName: String) throws {
        var callError: Error?
        let invoke = {
            do {
                try self.invokeScreenLockViaLoginFramework(actionName: actionName)
            } catch {
                callError = error
            }
        }

        if Thread.isMainThread {
            invoke()
        } else {
            DispatchQueue.main.sync(execute: invoke)
        }

        if let callError {
            throw callError
        }
    }

    private func invokeScreenLockViaLoginFramework(actionName: String) throws {
        let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        DiagnosticsLogger.record("Helper action \(actionName) starting private framework call on mainThread=\(Thread.isMainThread): \(frameworkPath) SACLockScreenImmediate")

        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            let message = String(cString: dlerror())
            DiagnosticsLogger.record("Helper action \(actionName) dlopen failed: \(message)")
            throw HelperActionError.custom("Failed to open login.framework: \(message)")
        }
        defer { dlclose(handle) }

        typealias LockFunction = @convention(c) () -> Void
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            let message = String(cString: dlerror())
            DiagnosticsLogger.record("Helper action \(actionName) dlsym failed: \(message)")
            throw HelperActionError.custom("Failed to resolve SACLockScreenImmediate: \(message)")
        }

        let lockScreen = unsafeBitCast(symbol, to: LockFunction.self)
        lockScreen()
        DiagnosticsLogger.record("Helper action \(actionName) private framework call completed")
    }

    private func runLoggedCommand(actionName: String, executableURL: URL, arguments: [String]) throws {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        DiagnosticsLogger.record("Helper action \(actionName) starting: \(executableURL.path) \(arguments.joined(separator: " "))")

        do {
            try process.run()
        } catch {
            DiagnosticsLogger.record(error: error, context: "Helper action \(actionName) failed to start")
            throw error
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        DiagnosticsLogger.record("Helper action \(actionName) finished with status=\(process.terminationStatus), reason=\(process.terminationReason.rawValue)")
        DiagnosticsLogger.record("Helper action \(actionName) stdout: \(stdout.isEmpty ? "<empty>" : stdout)")
        DiagnosticsLogger.record("Helper action \(actionName) stderr: \(stderr.isEmpty ? "<empty>" : stderr)")

        guard process.terminationStatus == 0 else {
            throw HelperActionError.commandFailed(
                actionName: actionName,
                status: process.terminationStatus,
                stderr: stderr.isEmpty ? stdout : stderr
            )
        }
    }
}

private extension HelperActionError {
    static func commandFailed(actionName: String, status: Int32, stderr: String) -> HelperActionError {
        .custom("\(actionName) command failed with status \(status): \(stderr)")
    }
}

private enum DiagnosticsLogger {
    private static let logURL: URL = {
        let fileManager = FileManager.default
        let root = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

        return root
            .appendingPathComponent("FamilyRulesAgent", isDirectory: true)
            .appendingPathComponent("Diagnostics.log")
    }()

    static func record(_ message: String) {
        let line = "[\(DiagnosticsLogFormatting.timestamp())] \(message)"
        try? DiagnosticsLogFileIO.append(line: line, to: logURL)
    }

    static func record(error: Error, context: String) {
        record("ERROR: \(context): \(error.localizedDescription)")
    }
}

let delegate = HelperDelegate()
delegate.run()

private final class HelperStateStore {
    private let formatter = ISO8601DateFormatter()

    private(set) var registration: HelperRegistrationPayload?
    private(set) var agentBundleIdentifier: String?
    private var lastHeartbeatAt: Date?
    private var lastObservedDeviceState = "Unknown"
    private var lastActionDescription: String?

    func update(with payload: AgentStatusPayload) {
        registration = payload.registration
        agentBundleIdentifier = payload.agentBundleIdentifier
        lastHeartbeatAt = payload.sentAt
        lastObservedDeviceState = payload.lastObservedDeviceState
    }

    func recordAction(_ description: String, at date: Date) {
        lastActionDescription = "\(description) at \(formatter.string(from: date))"
    }

    func statusPayload() -> HelperLifecycleStatusPayload {
        HelperLifecycleStatusPayload(
            lastHeartbeatAt: lastHeartbeatAt,
            lastObservedDeviceState: lastObservedDeviceState,
            lastActionDescription: lastActionDescription
        )
    }
}

private enum HelperActionError: LocalizedError {
    case lockFailed
    case custom(String)
    case logoutFailed(String)
    case missingTargetIdentifier
    case targetNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .lockFailed:
            return "The helper could not request screen lock."
        case let .custom(message):
            return message
        case let .logoutFailed(message):
            return "The helper could not request logout: \(message)"
        case .missingTargetIdentifier:
            return "The helper is missing the target app identifier."
        case let .targetNotRunning(identifier):
            return "The helper could not find a running app for \(identifier)."
        }
    }
}

private struct HelperPlaybackSnapshot {
    let identifier: String
    let name: String?
    let pid: pid_t?
    let isPlaying: Bool
}

private final class HelperMediaRemotePlaybackProbe {
    private typealias MRGetNowPlayingApplicationPID = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    private typealias MRGetNowPlayingApplicationIsPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void

    private let getNowPlayingApplicationPID: MRGetNowPlayingApplicationPID?
    private let getNowPlayingApplicationIsPlaying: MRGetNowPlayingApplicationIsPlaying?
    private let callbackQueue = DispatchQueue(label: "com.familyrules.helper.mediaremote")

    init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW) else {
            getNowPlayingApplicationPID = nil
            getNowPlayingApplicationIsPlaying = nil
            return
        }

        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") {
            getNowPlayingApplicationPID = unsafeBitCast(sym, to: MRGetNowPlayingApplicationPID.self)
        } else {
            getNowPlayingApplicationPID = nil
        }

        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getNowPlayingApplicationIsPlaying = unsafeBitCast(sym, to: MRGetNowPlayingApplicationIsPlaying.self)
        } else {
            getNowPlayingApplicationIsPlaying = nil
        }
        // Note: handle is intentionally not closed — the framework must remain loaded.
    }

    func snapshot() -> HelperPlaybackSnapshot? {
        guard let getPID = getNowPlayingApplicationPID else {
            DiagnosticsLogger.record("Helper playback probe: MediaRemote not loaded")
            return nil
        }

        let group = DispatchGroup()
        var pid: Int32 = 0
        var isPlaying: Bool = false

        group.enter()
        getPID(callbackQueue) { value in
            pid = value
            group.leave()
        }

        if let getIsPlaying = getNowPlayingApplicationIsPlaying {
            group.enter()
            getIsPlaying(callbackQueue) { value in
                isPlaying = value
                group.leave()
            }
        }

        let waited = group.wait(timeout: .now() + 2)
        DiagnosticsLogger.record("Helper playback probe: waited=\(waited == .success ? "ok" : "timeout") pid=\(pid) isPlaying=\(isPlaying)")

        guard waited == .success, isPlaying, pid > 0 else { return nil }

        guard let application = NSRunningApplication(processIdentifier: pid_t(pid)) else {
            DiagnosticsLogger.record("Helper playback probe: no running app for pid=\(pid)")
            return nil
        }

        let identifier = application.bundleIdentifier
            ?? application.bundleURL?.path(percentEncoded: false)
            ?? application.executableURL?.path(percentEncoded: false)
            ?? String(pid)

        return HelperPlaybackSnapshot(
            identifier: identifier,
            name: application.localizedName,
            pid: pid_t(pid),
            isPlaying: true
        )
    }
}
