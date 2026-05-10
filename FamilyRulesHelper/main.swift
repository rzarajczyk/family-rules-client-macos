import AppKit
import Foundation

final class HelperDelegate: NSObject, NSXPCListenerDelegate, FamilyRulesHelperXPCProtocol, @unchecked Sendable {
    private let listener = NSXPCListener.service()
    private let dateFormatter = ISO8601DateFormatter()
    private let stateStore = HelperStateStore()
    private let serverClient = HelperServerStateClient()
    private let clock: () -> Date
    /// Serializes all mutable state access. XPC callbacks arrive on arbitrary
    /// threads; this queue ensures HelperStateStore and reactivationTimer are
    /// never touched concurrently.
    private let queue = DispatchQueue(label: "com.familyrules.helper.delegate")
    private var reactivationTimer: Timer?

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
                updatePollingState()
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
    private func updatePollingState() {
        if stateStore.isAdminDisabled {
            startReactivationPollingIfNeeded()
        } else {
            reactivationTimer?.invalidate()
            reactivationTimer = nil
        }
    }

    // Must be called on `queue`.
    private func startReactivationPollingIfNeeded() {
        guard reactivationTimer == nil else { return }

        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            queue.async {
                Task { await self.pollForReactivation() }
            }
        }

        reactivationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollForReactivation() async {
        let registration = queue.sync { stateStore.registration }
        guard let registration else { return }

        do {
            let deviceState = try await serverClient.fetchDeviceState(registration: registration)
            let now = clock()
            queue.async { [self] in
                stateStore.recordPollResult(state: deviceState, at: now)
                if !LifecycleStateBridge.isAdminDisabled(deviceState) {
                    relaunchAgentIfPossible()
                    stateStore.markReactivated(at: now)
                    reactivationTimer?.invalidate()
                    reactivationTimer = nil
                }
            }
        } catch {
            let now = clock()
            queue.async { [self] in
                stateStore.recordPollFailure(error.localizedDescription, at: now)
            }
            DiagnosticsLogger.record(error: error, context: "Helper reactivation poll failed")
        }
    }

    // Must be called on `queue`.
    private func relaunchAgentIfPossible() {
        guard let bundleIdentifier = stateStore.agentBundleIdentifier else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    // Must be called on `queue`.
    private func performDeviceAction(_ action: HelperDeviceAction, targetIdentifier: String?) throws -> String {
        switch action {
        case .lockScreen:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/RemoteManagement/AppleVNCServer.bundle/Contents/Support/LockScreen.app/Contents/MacOS/LockScreen")
            try process.run()
            return "Lock requested"
        case .logout:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application \"System Events\" to log out"]
            try process.run()
            return "Logout requested"
        case .switchUser:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow")
            process.arguments = [">switch-user"]
            try process.run()
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
        let line = "[\(timestamp())] \(message)"
        let data = Data((line + "\n").utf8)
        let fileManager = FileManager.default

        try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: logURL.path(percentEncoded: false)) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    static func record(error: Error, context: String) {
        record("ERROR: \(context): \(error.localizedDescription)")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
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
    private var lastPollDescription: String?
    private var lastRelaunchDescription: String?
    private var lastActionDescription: String?
    private(set) var isAdminDisabled = false

    func update(with payload: AgentStatusPayload) {
        registration = payload.registration
        agentBundleIdentifier = payload.agentBundleIdentifier
        lastHeartbeatAt = payload.sentAt
        isAdminDisabled = payload.isAdminDisabled
        lastObservedDeviceState = payload.lastObservedDeviceState
    }

    func recordPollResult(state: String, at date: Date) {
        let normalized = LifecycleStateBridge.normalize(state)
        lastObservedDeviceState = normalized
        lastPollDescription = "ok at \(formatter.string(from: date))"
    }

    func recordPollFailure(_ message: String, at date: Date) {
        lastPollDescription = "failed at \(formatter.string(from: date)): \(message)"
    }

    func markReactivated(at date: Date) {
        isAdminDisabled = false
        lastRelaunchDescription = "reactivation requested at \(formatter.string(from: date))"
    }

    func recordAction(_ description: String, at date: Date) {
        lastActionDescription = "\(description) at \(formatter.string(from: date))"
    }

    func statusPayload() -> HelperLifecycleStatusPayload {
        HelperLifecycleStatusPayload(
            isAdminDisabled: isAdminDisabled,
            lastHeartbeatAt: lastHeartbeatAt,
            lastObservedDeviceState: lastObservedDeviceState,
            lastPollDescription: lastPollDescription,
            lastRelaunchDescription: lastRelaunchDescription,
            lastActionDescription: lastActionDescription
        )
    }
}

private actor HelperServerStateClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchDeviceState(registration: HelperRegistrationPayload) async throws -> String {
        let endpoint = try endpointURL(serverURL: registration.serverURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(basicAuthorization(username: registration.instanceId, password: registration.instanceToken), forHTTPHeaderField: "Authorization")

        // Use an encoded struct so the body stays consistent with the
        // shared payload type rather than a brittle hardcoded JSON string.
        let body = try JSONEncoder().encode(HelperZeroedReportPayload())
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HelperServerStateError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw HelperServerStateError.requestFailed(statusCode: httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(ReportResponsePayload.self, from: data)
        return decoded.deviceState
    }

    private func endpointURL(serverURL: String) throws -> URL {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed

        guard !normalized.isEmpty, let baseURL = URL(string: normalized), baseURL.scheme != nil else {
            throw HelperServerStateError.invalidServerURL
        }

        return baseURL.appending(path: "api").appending(path: "v2").appending(path: "report")
    }

    private func basicAuthorization(username: String, password: String) -> String {
        let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}

private struct ReportResponsePayload: Decodable {
    let deviceState: String
}

/// A minimal zeroed report payload used by the helper when polling the server
/// for device state during reactivation checks.  Keeping this as a typed struct
/// ensures the JSON shape stays in sync with the server contract.
private struct HelperZeroedReportPayload: Encodable {
    let screenTime: Int = 0
    let applications: [String: Int] = [:]
    let activeApps: [String] = []
}

private enum HelperServerStateError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case requestFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "The helper has an invalid server URL."
        case .invalidResponse:
            return "The helper received an invalid response."
        case let .requestFailed(statusCode):
            return "The helper received HTTP \(statusCode)."
        }
    }
}

private enum HelperActionError: LocalizedError {
    case lockFailed
    case logoutFailed(String)
    case missingTargetIdentifier
    case targetNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .lockFailed:
            return "The helper could not request screen lock."
        case let .logoutFailed(message):
            return "The helper could not request logout: \(message)"
        case .missingTargetIdentifier:
            return "The helper is missing the target app identifier."
        case let .targetNotRunning(identifier):
            return "The helper could not find a running app for \(identifier)."
        }
    }
}
