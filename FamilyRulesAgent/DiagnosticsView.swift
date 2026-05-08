import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var store: DiagnosticsStore
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FamilyRules")
                .font(.title2.weight(.semibold))
            LabeledContent("Menu Bar App", value: "Enabled")
            LabeledContent("Registration", value: appModel.registration == nil ? "Not registered" : "Registered")

            if let registration = appModel.registration {
                LabeledContent("Server URL", value: registration.serverURL)
                LabeledContent("Parent Username", value: registration.username)
                LabeledContent("Instance Name", value: registration.instanceName)
                LabeledContent("Instance ID", value: registration.instanceId)
            }

            LabeledContent("Helper Reachability", value: store.helperConnectionState)
            LabeledContent("Last Helper Reply", value: store.helperLastReply)
            LabeledContent("Service Management", value: store.serviceManagementState)

            if let startupErrorMessage = appModel.startupErrorMessage {
                Text(startupErrorMessage)
                    .foregroundStyle(.orange)
            }

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
        .frame(minWidth: 620, minHeight: 320)
    }
}
