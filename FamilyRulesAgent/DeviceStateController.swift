import Foundation

@MainActor
protocol DeviceStateControlling: AnyObject {
    var normalizedState: String { get }
    var statusDescription: String { get }
    var countdownPresentation: StateCountdownPresentation? { get }
    var restrictedAppBlockingEnabled: Bool { get }
    var shouldPresentCompactCountdown: Bool { get }
    var shouldEnforceSwitchUserLoop: Bool { get }
    func apply(rawState: String, extra: String?)
    func clear()
}

@MainActor
final class DeviceStateController: ObservableObject, DeviceStateControlling {
    @Published private(set) var normalizedState = "ACTIVE"
    @Published private(set) var statusDescription = "Active"
    @Published private(set) var countdownPresentation: StateCountdownPresentation?
    @Published private(set) var restrictedAppBlockingEnabled = false
    @Published private(set) var shouldPresentCompactCountdown = false
    @Published private(set) var shouldEnforceSwitchUserLoop = false

    private let helperClient: any HelperLifecycleClientProtocol
    private let sessionActionExecutor: (HelperDeviceAction) throws -> String?
    private let countdownDurationProvider: (String, String?) -> Int
    private let sleep: @Sendable (Int) async throws -> Void
    private let now: () -> Date

    private var countdownTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?
    private var activeCountdownState: String?
    private var countdownDeadline: Date?

    init(
        helperClient: any HelperLifecycleClientProtocol = HelperXPCClient(),
        sessionActionExecutor: @escaping (HelperDeviceAction) throws -> String? = SessionActionExecutor.execute,
        countdownDurationProvider: @escaping (String, String?) -> Int = DeviceStateController.defaultCountdownDuration,
        sleep: @escaping @Sendable (Int) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.helperClient = helperClient
        self.sessionActionExecutor = sessionActionExecutor
        self.countdownDurationProvider = countdownDurationProvider
        self.sleep = sleep
        self.now = Date.init
    }

    init(
        helperClient: any HelperLifecycleClientProtocol,
        sessionActionExecutor: @escaping (HelperDeviceAction) throws -> String? = SessionActionExecutor.execute,
        countdownDurationProvider: @escaping (String, String?) -> Int,
        sleep: @escaping @Sendable (Int) async throws -> Void,
        now: @escaping () -> Date
    ) {
        self.helperClient = helperClient
        self.sessionActionExecutor = sessionActionExecutor
        self.countdownDurationProvider = countdownDurationProvider
        self.sleep = sleep
        self.now = now
    }

    func apply(rawState: String, extra: String?) {
        let normalized = LifecycleStateBridge.normalize(rawState)
        normalizedState = normalized

        if refreshExistingCountdownIfNeeded(for: normalized) {
            return
        }

        countdownTask?.cancel()
        countdownTask = nil
        executionTask?.cancel()
        executionTask = nil
        countdownPresentation = nil
        restrictedAppBlockingEnabled = false
        shouldPresentCompactCountdown = false
        shouldEnforceSwitchUserLoop = false
        activeCountdownState = nil
        countdownDeadline = nil

        switch normalized {
        case "ACTIVE":
            statusDescription = "Active"
        case "ADMIN_DISABLED":
            statusDescription = "Admin Disabled"
        case "BLOCK_RESTRICTED_APPS":
            statusDescription = "Blocking Restricted Apps"
            restrictedAppBlockingEnabled = true
        case "LOCK_SCREEN":
            statusDescription = String.localized("Screen Locked")
        case "LOGOUT":
            statusDescription = "Switching User"
            shouldEnforceSwitchUserLoop = true
            executeHelperAction(for: normalized)
        case "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT", "LOCK_SCREEN_WITH_TIMEOUT", "LOGOUT_WITH_TIMEOUT":
            let seconds = max(1, countdownDurationProvider(normalized, extra))
            statusDescription = countdownStatusDescription(for: normalized, secondsRemaining: seconds)
            startCountdown(for: normalized, secondsRemaining: seconds)
        default:
            statusDescription = normalized.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    func clear() {
        countdownTask?.cancel()
        countdownTask = nil
        executionTask?.cancel()
        executionTask = nil
        normalizedState = "ACTIVE"
        statusDescription = "Active"
        countdownPresentation = nil
        restrictedAppBlockingEnabled = false
        shouldPresentCompactCountdown = false
        shouldEnforceSwitchUserLoop = false
        activeCountdownState = nil
        countdownDeadline = nil
    }

    private func startCountdown(for normalized: String, secondsRemaining: Int) {
        activeCountdownState = normalized
        countdownDeadline = now().addingTimeInterval(TimeInterval(secondsRemaining))
        countdownPresentation = countdownPresentation(for: normalized, secondsRemaining: secondsRemaining)
        shouldPresentCompactCountdown = normalized == "LOCK_SCREEN_WITH_TIMEOUT" || normalized == "LOGOUT_WITH_TIMEOUT"

        countdownTask = Task { [weak self] in
            guard let self else { return }

            var remaining = secondsRemaining
            while remaining > 0 && !Task.isCancelled {
                self.statusDescription = self.countdownStatusDescription(for: normalized, secondsRemaining: remaining)
                self.countdownPresentation = self.countdownPresentation(for: normalized, secondsRemaining: remaining)

                do {
                    try await self.sleep(1)
                } catch {
                    return
                }

                remaining -= 1

                // Update display to show the decremented value (including 0) before
                // the loop exits and the action fires, so the counter reaches zero.
                if remaining >= 0 {
                    self.statusDescription = self.countdownStatusDescription(for: normalized, secondsRemaining: remaining)
                    self.countdownPresentation = self.countdownPresentation(for: normalized, secondsRemaining: remaining)
                }
            }

            guard !Task.isCancelled else { return }
            self.countdownPresentation = nil
            self.shouldPresentCompactCountdown = false
            self.activeCountdownState = nil
            self.countdownDeadline = nil

            switch normalized {
            case "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT":
                self.normalizedState = "BLOCK_RESTRICTED_APPS"
                self.statusDescription = "Blocking Restricted Apps"
                self.restrictedAppBlockingEnabled = true
            case "LOCK_SCREEN_WITH_TIMEOUT":
                self.normalizedState = "LOCK_SCREEN"
                self.statusDescription = String.localized("Screen Locked")
            case "LOGOUT_WITH_TIMEOUT":
                self.normalizedState = "LOGOUT"
                self.statusDescription = "Switching User"
                self.shouldEnforceSwitchUserLoop = true
                self.executeHelperAction(for: "LOGOUT")
            default:
                break
            }
        }
    }

    private func refreshExistingCountdownIfNeeded(for normalized: String) -> Bool {
        guard normalized == activeCountdownState,
              countdownTask != nil,
              let secondsRemaining = currentCountdownSecondsRemaining()
        else {
            return false
        }

        countdownPresentation = countdownPresentation(for: normalized, secondsRemaining: secondsRemaining)
        statusDescription = countdownStatusDescription(for: normalized, secondsRemaining: secondsRemaining)
        shouldPresentCompactCountdown = normalized == "LOCK_SCREEN_WITH_TIMEOUT" || normalized == "LOGOUT_WITH_TIMEOUT"
        return true
    }

    private func currentCountdownSecondsRemaining() -> Int? {
        guard let countdownDeadline else { return nil }
        return max(0, Int(ceil(countdownDeadline.timeIntervalSince(now()))))
    }

    private func executeHelperAction(for normalized: String) {
        guard let action = LifecycleStateBridge.helperAction(for: normalized) else { return }
        executeHelperAction(action: action)
    }

    private func executeHelperAction(action: HelperDeviceAction) {
        if action != .switchUser {
            shouldEnforceSwitchUserLoop = false
        }

        executionTask = Task { [weak self] in
            guard let self else { return }

            do {
                let reply: String
                if let localReply = try self.sessionActionExecutor(action) {
                    reply = localReply
                } else {
                    let request = HelperDeviceActionRequest(action: action, requestedAt: Date())
                    reply = try await self.helperClient.executeDeviceAction(request)
                }
                self.statusDescription = reply
            } catch {
                DiagnosticsLogger.record(error: error, context: "Failed to execute helper action \(action.rawValue)")
                self.statusDescription = error.localizedDescription
            }
        }
    }

    private func countdownPresentation(for normalized: String, secondsRemaining: Int) -> StateCountdownPresentation {
        switch normalized {
        case "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT":
            return StateCountdownPresentation(
                title: "Restricted apps will be blocked",
                message: "Open restricted apps will be blocked when the countdown finishes.",
                secondsRemaining: secondsRemaining
            )
        case "LOCK_SCREEN_WITH_TIMEOUT":
            return StateCountdownPresentation(
                title: String.localized("Screen lock scheduled"),
                message: String.localized("Save your work before the screen locks."),
                secondsRemaining: secondsRemaining
            )
        default:
            return StateCountdownPresentation(
                title: "User switch scheduled",
                message: "Save your work before macOS switches to the login window.",
                secondsRemaining: secondsRemaining
            )
        }
    }

    private func countdownStatusDescription(for normalized: String, secondsRemaining: Int) -> String {
        switch normalized {
        case "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT":
            return "Blocking restricted apps in \(secondsRemaining)s"
        case "LOCK_SCREEN_WITH_TIMEOUT":
            return String(format: String.localized("Locking in %ds"), secondsRemaining)
        default:
            return "Switching user in \(secondsRemaining)s"
        }
    }

    nonisolated private static func defaultCountdownDuration(state: String, extra: String?) -> Int {
        if let extra,
           let value = Int(extra.trimmingCharacters(in: .whitespacesAndNewlines)),
           value > 0 {
            return value
        }

        switch state {
        case "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT":
            return 60
        case "LOCK_SCREEN_WITH_TIMEOUT", "LOGOUT_WITH_TIMEOUT":
            return 60
        default:
            return 0
        }
    }
}
