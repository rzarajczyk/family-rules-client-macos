import Combine
import Foundation
import ServiceManagement

@MainActor
final class DiagnosticsStore: ObservableObject {
    @Published var helperConnectionState = "Idle"
    @Published var helperLastReply = "No ping yet"
    @Published var serviceManagementState = ServiceManagementBridge.registrationDescription()

    func refreshServiceManagementState() {
        serviceManagementState = ServiceManagementBridge.registrationDescription()
    }

    func performPing() {
        helperConnectionState = "Connecting"

        Task {
            do {
                let reply = try await HelperXPCClient().ping()
                helperConnectionState = "Reachable"
                helperLastReply = reply
            } catch {
                helperConnectionState = "Failed"
                helperLastReply = error.localizedDescription
            }
        }
    }
}

enum ServiceManagementBridge {
    static func registrationDescription() -> String {
        if #available(macOS 13.0, *) {
            return "mainApp: \(SMAppService.mainApp.status.description)"
        }

        return "SMAppService requires macOS 13+"
    }
}

@available(macOS 13.0, *)
private extension SMAppService.Status {
    var description: String {
        switch self {
        case .enabled:
            return "enabled"
        case .notFound:
            return "notFound"
        case .notRegistered:
            return "notRegistered"
        case .requiresApproval:
            return "requiresApproval"
        @unknown default:
            return "unknown"
        }
    }
}
