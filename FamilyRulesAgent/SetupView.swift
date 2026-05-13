import ApplicationServices
import Foundation
import SwiftUI

// MARK: - Accessibility permission helper

enum AccessibilityPermission {
    static var isGranted: Bool {
        // Use the raw string to avoid concurrency issues with the CF constant.
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings to the Accessibility privacy pane.
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - SetupView

struct SetupView: View {
    enum StartingStep {
        case registration
        case permissions
    }

    @ObservedObject var appModel: AppModel
    let startingStep: StartingStep
    /// Called immediately after successful registration (step 1). Use to start sync / open dashboard.
    let onRegistered: () -> Void
    /// Called when the user taps Done on the permissions step (step 2). Use to close the window.
    let onFinished: () -> Void

    @State private var currentStep: Step

    private enum Step {
        case registration
        case permissions
    }

    init(
        appModel: AppModel,
        startingStep: StartingStep = .registration,
        onRegistered: @escaping () -> Void = {},
        onFinished: @escaping () -> Void
    ) {
        self.appModel = appModel
        self.startingStep = startingStep
        self.onRegistered = onRegistered
        self.onFinished = onFinished
        _currentStep = State(initialValue: startingStep == .permissions ? .permissions : .registration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepIndicator
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 20)

            Divider()

            switch currentStep {
            case .registration:
                RegistrationStepView(appModel: appModel) {
                    onRegistered()
                    currentStep = .permissions
                }
            case .permissions:
                PermissionsStepView(onDone: onFinished)
            }
        }
        .frame(minWidth: 620, minHeight: 360)
    }

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            stepLabel(number: 1, title: String(localized: "Connect"), isActive: currentStep == .registration, isDone: currentStep == .permissions)
            stepConnector(filled: currentStep == .permissions)
            stepLabel(number: 2, title: String(localized: "Permissions"), isActive: currentStep == .permissions, isDone: false)
        }
    }

    private func stepLabel(number: Int, title: String, isActive: Bool, isDone: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isActive || isDone ? Color.accentColor : Color(nsColor: .separatorColor))
                    .frame(width: 26, height: 26)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isActive ? .white : Color(nsColor: .tertiaryLabelColor))
                }
            }
            Text(title)
                .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
        }
    }

    private func stepConnector(filled: Bool) -> some View {
        Rectangle()
            .fill(filled ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(height: 2)
            .padding(.horizontal, 8)
    }
}

// MARK: - Step 1: Registration

private struct RegistrationStepView: View {
    @ObservedObject var appModel: AppModel
    let onNext: () -> Void

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var instanceName = LocalAccountIdentity.currentUserScopedInstanceName()
    @State private var errorMessage: String?
    @State private var isRegistering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect to Server")
                    .font(.title2.weight(.semibold))
                Text("Register this Mac with your FamilyRules server.")
                    .foregroundStyle(.secondary)
            }

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
                Button(isRegistering ? "Registering..." : "Register & Continue") {
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
                onNext()
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

// MARK: - Step 2: Permissions

struct PermissionsStepView: View {
    let onDone: () -> Void

    @State private var isGranted: Bool = AccessibilityPermission.isGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Grant Permissions")
                    .font(.title2.weight(.semibold))
                Text("FamilyRules needs Accessibility access to minimise restricted app windows.")
                    .foregroundStyle(.secondary)
            }

            permissionRow

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    onDone()
                }
                .disabled(!isGranted)
                .keyboardShortcut(.defaultAction)

                if !isGranted {
                    Text("Grant permission above to continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard !isGranted else { return }  // stop checking once granted
            isGranted = AccessibilityPermission.isGranted
        }
    }

    private var permissionRow: some View {
        HStack(spacing: 16) {
            Image(systemName: "accessibility")
                .font(.system(size: 28))
                .foregroundStyle(isGranted ? .green : .orange)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility")
                    .font(.headline)
                Text("Required to minimise windows of blocked apps.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.weight(.semibold))
            } else {
                Button("Open System Settings") {
                    AccessibilityPermission.openSystemSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
