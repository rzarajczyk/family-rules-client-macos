import Foundation
import ServiceManagement

@MainActor
protocol LifecycleControlling: AnyObject {
    var isAdminDisabled: Bool { get }
    var statusDescription: String { get }
    var loginItemStatusDescription: String { get }
    var helperStatusDescription: String { get }
    var countdownPresentation: StateCountdownPresentation? { get }
    var restrictedAppBlockingEnabled: Bool { get }
    var shouldPresentCompactCountdown: Bool { get }
    var shouldEnforceSwitchUserLoop: Bool { get }
    func start(registration: RegistrationRecord)
    func updateServerDeviceState(_ rawState: String, extra: String?)
    func performRestrictedAppFallbackTermination(targetIdentifier: String) async -> Bool
    func stop()
    func refreshDiagnostics() async
}

@MainActor
final class LifecycleController: ObservableObject, LifecycleControlling {
    @Published private(set) var isAdminDisabled = false
    @Published private(set) var loginItemStatusDescription = ServiceManagementBridge.registrationDescription()
    @Published private(set) var helperStatusDescription = "Unknown"
    @Published private(set) var lastObservedDeviceState = "Unknown"

    var statusDescription: String {
        guard registration != nil else { return "Inactive" }
        if isAdminDisabled { return "Admin Disabled" }
        switch lastObservedDeviceState {
        case "ACTIVE":
            return "Protected"
        default:
            return deviceStateController.statusDescription
        }
    }

    var countdownPresentation: StateCountdownPresentation? {
        deviceStateController.countdownPresentation
    }

    var restrictedAppBlockingEnabled: Bool {
        deviceStateController.restrictedAppBlockingEnabled
    }

    var shouldPresentCompactCountdown: Bool {
        deviceStateController.shouldPresentCompactCountdown
    }

    var shouldEnforceSwitchUserLoop: Bool {
        deviceStateController.shouldEnforceSwitchUserLoop
    }

    var normalizedState: String {
        deviceStateController.normalizedState
    }

    private let helperClient: any HelperLifecycleClientProtocol
    private let deviceStateController: any DeviceStateControlling
    private let bundleIdentifierProvider: () -> String
    private let now: () -> Date
    private let loginItemRegistrar: () throws -> String
    private var registration: RegistrationRecord?

    init(
        helperClient: any HelperLifecycleClientProtocol = HelperXPCClient(),
        deviceStateController: (any DeviceStateControlling)? = nil,
        bundleIdentifierProvider: @escaping () -> String = {
            Bundle.main.bundleIdentifier ?? "com.familyrules.agent"
        },
        now: @escaping () -> Date = Date.init,
        loginItemRegistrar: @escaping () throws -> String = {
            try ServiceManagementBridge.registerMainAppIfAvailable()
            return ServiceManagementBridge.registrationDescription()
        }
    ) {
        self.helperClient = helperClient
        self.deviceStateController = deviceStateController ?? DeviceStateController(helperClient: helperClient)
        self.bundleIdentifierProvider = bundleIdentifierProvider
        self.now = now
        self.loginItemRegistrar = loginItemRegistrar
    }

    func start(registration: RegistrationRecord) {
        self.registration = registration
        // Always reset admin-disabled on a fresh start; the server state
        // will be re-established on the first report cycle.
        isAdminDisabled = false
        lastObservedDeviceState = "ACTIVE"
        deviceStateController.clear()

        do {
            loginItemStatusDescription = try loginItemRegistrar()
        } catch {
            DiagnosticsLogger.record(error: error, context: "Failed to register login item")
            loginItemStatusDescription = error.localizedDescription
        }

        Task {
            await updateHelperStatus()
        }
    }

    func updateServerDeviceState(_ rawState: String, extra: String?) {
        guard registration != nil else { return }

        let normalizedState = LifecycleStateBridge.normalize(rawState)
        let shouldBeAdminDisabled = LifecycleStateBridge.isAdminDisabled(normalizedState)
        lastObservedDeviceState = normalizedState
        deviceStateController.apply(rawState: normalizedState, extra: extra)

        if isAdminDisabled != shouldBeAdminDisabled {
            isAdminDisabled = shouldBeAdminDisabled
        }
        objectWillChange.send()

        // Always push to helper so the heartbeat timestamp stays fresh,
        // regardless of whether the local boolean changed.
        Task {
            await updateHelperStatus(lastObservedState: normalizedState)
        }
    }

    func stop() {
        // Notify the helper that the agent is going inactive so it can
        // stop its reactivation timer and clear stale state.
        if let registration {
            let payload = AgentStatusPayload(
                registration: HelperRegistrationPayload(
                    serverURL: registration.serverURL,
                    username: registration.username,
                    instanceId: registration.instanceId,
                    instanceToken: registration.instanceToken,
                    instanceName: registration.instanceName
                ),
                agentBundleIdentifier: bundleIdentifierProvider(),
                isAdminDisabled: false,
                lastObservedDeviceState: "ACTIVE",
                sentAt: now()
            )
            Task {
                _ = try? await helperClient.updateAgentStatus(payload)
            }
        }

        self.registration = nil
        deviceStateController.clear()
        lastObservedDeviceState = "Unknown"
        isAdminDisabled = false
        objectWillChange.send()
    }

    func performRestrictedAppFallbackTermination(targetIdentifier: String) async -> Bool {
        let request = HelperDeviceActionRequest(action: .terminateApp, targetIdentifier: targetIdentifier, requestedAt: now())

        do {
            let reply = try await helperClient.executeDeviceAction(request)
            helperStatusDescription = reply
            return true
        } catch {
            DiagnosticsLogger.record(error: error, context: "Restricted app fallback termination failed")
            helperStatusDescription = error.localizedDescription
            return false
        }
    }

    func refreshDiagnostics() async {
        loginItemStatusDescription = ServiceManagementBridge.registrationDescription()

        do {
            let status = try await helperClient.fetchLifecycleStatus()
            helperStatusDescription = helperDescription(from: status)
        } catch {
            DiagnosticsLogger.record(error: error, context: "Failed to refresh lifecycle diagnostics")
            helperStatusDescription = error.localizedDescription
        }
    }

    private func updateHelperStatus(lastObservedState: String? = nil) async {
        guard let registration else { return }

        let payload = AgentStatusPayload(
            registration: HelperRegistrationPayload(
                serverURL: registration.serverURL,
                username: registration.username,
                instanceId: registration.instanceId,
                instanceToken: registration.instanceToken,
                instanceName: registration.instanceName
            ),
            agentBundleIdentifier: bundleIdentifierProvider(),
            isAdminDisabled: isAdminDisabled,
            lastObservedDeviceState: lastObservedDeviceState,
            sentAt: now()
        )

        do {
            let helperReply = try await helperClient.updateAgentStatus(payload)
            if let lastObservedState {
                helperStatusDescription = "\(helperReply); state=\(lastObservedState)"
            } else {
                helperStatusDescription = helperReply
            }
        } catch {
            DiagnosticsLogger.record(error: error, context: "Failed to update helper status")
            helperStatusDescription = error.localizedDescription
        }
    }

    private func helperDescription(from status: HelperLifecycleStatusPayload) -> String {
        let mode = status.isAdminDisabled ? "admin-disabled" : "active"
        let heartbeat = status.lastHeartbeatAt.map(timestampString) ?? "none"
        let poll = status.lastPollDescription ?? "none"
        let relaunch = status.lastRelaunchDescription ?? "none"
        let action = status.lastActionDescription ?? "none"
        return "mode=\(mode), heartbeat=\(heartbeat), poll=\(poll), relaunch=\(relaunch), action=\(action), state=\(status.lastObservedDeviceState)"
    }

    private func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
