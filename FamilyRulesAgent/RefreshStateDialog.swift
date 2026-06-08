import SwiftUI

struct RefreshStateDialog: View {
    @ObservedObject var syncController: SyncController
    let onDismiss: () -> Void

    @State private var isLoading = true
    @State private var outcome: ManualRefreshOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String.localized("Device State"))
                .font(.title2.weight(.semibold))

            Group {
                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(String.localized("Sending report to server…"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                } else if let outcome {
                    refreshContent(for: outcome)
                }
            }

            HStack {
                Spacer()
                Button(String.localized("Close"), action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .task {
            await performRefresh()
        }
    }

    @ViewBuilder
    private func refreshContent(for outcome: ManualRefreshOutcome) -> some View {
        switch outcome {
        case let .success(deviceState, extra, serverCommands):
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    String(
                        format: String.localized("Current device state: %@"),
                        localizedDeviceStateLabel(for: deviceState)
                    )
                )

                if let extra, !extra.isEmpty {
                    Text(String(format: String.localized("Details: %@"), extra))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(commandsSummary(serverCommands))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .unreachable:
            Text(String.localized("Could not reach the server. The device state shown may be out of date."))
                .foregroundStyle(.red)

        case let .error(message):
            Text(String(format: String.localized("Failed to refresh: %@"), message))
                .foregroundStyle(.red)
        }
    }

    private func performRefresh() async {
        isLoading = true
        outcome = await syncController.manualRefresh()
        isLoading = false
    }

    private func localizedDeviceStateLabel(for rawState: String) -> String {
        switch LifecycleStateBridge.normalize(rawState) {
        case "ACTIVE":
            return String.localized("Active (no restrictions)")
        case "BLOCK_RESTRICTED_APPS":
            return String.localized("Apps blocked")
        case "BLOCK_RESTRICTED_APPS_WITH_TIMEOUT":
            return String.localized("Apps blocked (with countdown)")
        default:
            return rawState
        }
    }

    private func commandsSummary(_ commands: [ServerCommandPayload]) -> String {
        guard !commands.isEmpty else {
            return String.localized("No server commands received.")
        }

        let names = commands.map(\.commandName).joined(separator: ", ")
        return String(format: String.localized("Server commands: %@"), names)
    }
}
