import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var store: DiagnosticsStore
    @ObservedObject var appModel: AppModel
    @ObservedObject var activityMonitor: ActivityMonitor
    @ObservedObject var lifecycleController: LifecycleController
    @ObservedObject var syncController: SyncController

    var body: some View {
        ScrollView {
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

                Divider()

                LabeledContent("Screen Awake", value: activityMonitor.isScreenAwake ? "Yes" : "No")
                LabeledContent("Session Active", value: activityMonitor.isSessionActive ? "Yes" : "No")
                LabeledContent("Foreground App", value: activityMonitor.frontmostApplicationName)
                LabeledContent("Visible Apps", value: "\(activityMonitor.visibleAppCount)")

                Divider()

                LabeledContent("Sync Status", value: syncController.syncStatus)
                LabeledContent("Last Client-Info", value: syncController.lastClientInfoDescription)
                LabeledContent("Last Report", value: syncController.lastReportDescription)
                LabeledContent("Last Device State", value: syncController.lastDeviceState)
                LabeledContent("Pending Commands", value: "\(syncController.pendingCommandCount)")
                LabeledContent("Last Command", value: syncController.lastCommandDescription)
                if let countdown = lifecycleController.countdownPresentation {
                    LabeledContent("Countdown", value: "\(countdown.title): \(countdown.secondsRemaining)s")
                }

                if let syncErrorMessage = syncController.lastErrorMessage {
                    Text(syncErrorMessage)
                        .foregroundStyle(.red)
                }

                if let commandErrorMessage = syncController.lastCommandErrorMessage {
                    Text(commandErrorMessage)
                        .foregroundStyle(.red)
                }

                Divider()

                LabeledContent("Helper Reachability", value: store.helperConnectionState)
                LabeledContent("Last Helper Reply", value: store.helperLastReply)
                LabeledContent("Service Management", value: store.serviceManagementState)
                LabeledContent("Log File") {
                    Button(store.logFileLocation) {
                        store.openLogFile()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .underline()
                    .textSelection(.enabled)
                }
                LabeledContent("Lifecycle", value: lifecycleController.statusDescription)
                LabeledContent("Login Item", value: lifecycleController.loginItemStatusDescription)
                LabeledContent("Helper Lifecycle", value: lifecycleController.helperStatusDescription)

                if let startupErrorMessage = appModel.startupErrorMessage {
                    Text(startupErrorMessage)
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Sync Log")
                        .font(.headline)

                    if syncController.recentLogLines.isEmpty {
                        Text("No sync activity yet")
                            .foregroundStyle(.secondary)
                    } else {
                        // Use enumerated offset as identity so identical log lines are
                        // each rendered as distinct rows rather than being de-duplicated by SwiftUI.
                        ForEach(Array(syncController.recentLogLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
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
        }
        .frame(minWidth: 700, minHeight: 520)
    }
}
