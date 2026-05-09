import Foundation

@MainActor
protocol DeviceStateControlling: AnyObject {
    var normalizedState: String { get }
    var statusDescription: String { get }
    var countdownPresentation: StateCountdownPresentation? { get }
    var restrictedAppBlockingEnabled: Bool { get }
    func apply(rawState: String, extra: String?)
    func clear()
}

@MainActor
final class DeviceStateController: ObservableObject, DeviceStateControlling {
    @Published private(set) var normalizedState = "ACTIVE"
    @Published private(set) var statusDescription = "Active"
    @Published private(set) var countdownPresentation: StateCountdownPresentation?
    @Published private(set) var restrictedAppBlockingEnabled = false

    private let helperClient: any HelperLifecycleClientProtocol
    private let countdownDurationProvider: (String, String?) -> Int
    private let sleep: @Sendable (Int) async throws -> Void

    private var countdownTask: Task<Void, Never>?
    private var executionTask: Task<Void, Never>?

    init(
        helperClient: any HelperLifecycleClientProtocol = HelperXPCClient(),
        countdownDurationProvider: @escaping (String, String?) -> Int = DeviceStateController.defaultCountdownDuration,
        sleep: @escaping @Sendable (Int) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.helperClient = helperClient
        self.countdownDurationProvider = countdownDurationProvider
        self.sleep = sleep
    }

    func apply(rawState: String, extra: String?) {
        let normalized = LifecycleStateBridge.normalize(rawState)
        normalizedState = normalized

        countdownTask?.cancel()
        countdownTask = nil
        executionTask?.cancel()
        executionTask = nil
        countdownPresentation = nil
        restrictedAppBlockingEnabled = false

        switch normalized {
        case "ACTIVE":
            statusDescription = "Active"
        case "ADMIN_DISABLED":
            statusDescription = "Admin Disabled"
        case "BLOCK_RESTRICTED_APPS":
            statusDescription = "Blocking Restricted Apps"
            restrictedAppBlockingEnabled = true
        case "LOCK_SCREEN":
            statusDescription = "Locking Screen"
            executeHelperAction(for: normalized)
        case "LOGOUT":
            statusDescription = "Logging Out"
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
    }

    private func startCountdown(for normalized: String, secondsRemaining: Int) {
        countdownPresentation = countdownPresentation(for: normalized, secondsRemaining: secondsRemaining)

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

            switch normalized {
            case "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT":
                self.normalizedState = "BLOCK_RESTRICTED_APPS"
                self.statusDescription = "Blocking Restricted Apps"
                self.restrictedAppBlockingEnabled = true
            case "LOCK_SCREEN_WITH_TIMEOUT":
                self.normalizedState = "LOCK_SCREEN"
                self.statusDescription = "Locking Screen"
                self.executeHelperAction(for: "LOCK_SCREEN")
            case "LOGOUT_WITH_TIMEOUT":
                self.normalizedState = "LOGOUT"
                self.statusDescription = "Logging Out"
                self.executeHelperAction(for: "LOGOUT")
            default:
                break
            }
        }
    }

    private func executeHelperAction(for normalized: String) {
        guard let action = LifecycleStateBridge.helperAction(for: normalized) else { return }

        executionTask = Task { [weak self] in
            guard let self else { return }
            let request = HelperDeviceActionRequest(action: action, requestedAt: Date())

            do {
                let reply = try await self.helperClient.executeDeviceAction(request)
                self.statusDescription = reply
            } catch {
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
                title: "Screen lock scheduled",
                message: "This Mac will lock soon.",
                secondsRemaining: secondsRemaining
            )
        default:
            return StateCountdownPresentation(
                title: "Logout scheduled",
                message: "This macOS session will log out soon.",
                secondsRemaining: secondsRemaining
            )
        }
    }

    private func countdownStatusDescription(for normalized: String, secondsRemaining: Int) -> String {
        switch normalized {
        case "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT":
            return "Blocking restricted apps in \(secondsRemaining)s"
        case "LOCK_SCREEN_WITH_TIMEOUT":
            return "Locking in \(secondsRemaining)s"
        default:
            return "Logging out in \(secondsRemaining)s"
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
