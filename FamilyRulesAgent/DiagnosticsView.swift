import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var store: DiagnosticsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FamilyRules Step 1")
                .font(.title2.weight(.semibold))

            Text("Signed app and helper skeleton diagnostics")
                .foregroundStyle(.secondary)

            LabeledContent("Menu Bar App", value: "Enabled")
            LabeledContent("Helper Reachability", value: store.helperConnectionState)
            LabeledContent("Last Helper Reply", value: store.helperLastReply)
            LabeledContent("Service Management", value: store.serviceManagementState)

            HStack {
                Button("Ping Helper") {
                    store.performPing()
                }

                Button("Refresh") {
                    store.refreshServiceManagementState()
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 240)
    }
}
