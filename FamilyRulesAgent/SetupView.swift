import Foundation
import SwiftUI

struct SetupView: View {
    @ObservedObject var appModel: AppModel
    let onRegistrationCompleted: () -> Void

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var instanceName = Host.current().localizedName ?? "My Mac"
    @State private var errorMessage: String?
    @State private var isRegistering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("FamilyRules Setup")
                .font(.title.weight(.semibold))

            Text("Register this Mac with your FamilyRules server before the app can switch into background monitoring mode.")
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Server URL")
                        .foregroundStyle(.secondary)
                    TextField("https://example.com", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Parent Username")
                        .foregroundStyle(.secondary)
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Parent Password")
                        .foregroundStyle(.secondary)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Instance Name")
                        .foregroundStyle(.secondary)
                    TextField("Child MacBook", text: $instanceName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let startupErrorMessage = appModel.startupErrorMessage {
                Text(startupErrorMessage)
                    .foregroundStyle(.orange)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(isRegistering ? "Registering..." : "Register") {
                    register()
                }
                .disabled(isRegistering)

                if isRegistering {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 320)
    }

    private func register() {
        errorMessage = validateFields()
        guard errorMessage == nil else { return }

        isRegistering = true

        Task {
            do {
                try await appModel.register(
                    serverURL: serverURL,
                    username: username,
                    password: password,
                    instanceName: instanceName
                )

                password = ""
                errorMessage = nil
                isRegistering = false
                onRegistrationCompleted()
            } catch {
                errorMessage = error.localizedDescription
                DiagnosticsLogger.record(error: error, context: "Registration failed from setup view")
                isRegistering = false
            }
        }
    }

    private func validateFields() -> String? {
        if serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a server URL."
        }

        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the parent username."
        }

        if password.isEmpty {
            return "Enter the parent password."
        }

        if instanceName.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 {
            return "Enter an instance name with at least 3 characters."
        }

        return nil
    }
}
