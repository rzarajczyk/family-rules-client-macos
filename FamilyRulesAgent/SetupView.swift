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
    /// Called when the user finishes the setup flow after completing permissions.
    let onFinished: () -> Void

    @State private var currentStep: Step

    private enum Step {
        case registration
        case permissions
    }

    init(
        appModel: AppModel,
        startingStep: StartingStep = .registration,
        onFinished: @escaping () -> Void
    ) {
        self.appModel = appModel
        self.startingStep = startingStep
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

    @State private var isAccessibilityGranted = AccessibilityPermission.isGranted
    @State private var isStartAtLoginEnabled = ServiceManagementBridge.isMainAppEnabled
    @State private var startAtLoginStatus = ServiceManagementBridge.registrationDescription()
    @State private var startAtLoginError: String?
    @State private var isRegisteringStartAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Grant Permissions")
                    .font(.title2.weight(.semibold))
                Text("FamilyRules needs Accessibility access to minimise restricted app windows.")
                    .foregroundStyle(.secondary)
            }

            accessibilityPermissionRow
            startAtLoginPermissionRow

            if let startAtLoginError {
                Text(startAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    onDone()
                }
                .disabled(!isAccessibilityGranted || !isStartAtLoginEnabled)
                .keyboardShortcut(.defaultAction)

                if !isAccessibilityGranted || !isStartAtLoginEnabled {
                    Text("Complete both permissions above to continue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .onAppear {
            refreshPermissionState()
            if !isStartAtLoginEnabled {
                enableStartAtLogin()
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard !isAccessibilityGranted || !isStartAtLoginEnabled else { return }
            refreshPermissionState()
        }
    }

    private var accessibilityPermissionRow: some View {
        HStack(spacing: 16) {
            Image(systemName: "accessibility")
                .font(.system(size: 28))
                .foregroundStyle(isAccessibilityGranted ? .green : .orange)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility")
                    .font(.headline)
                Text("Required to minimise windows of blocked apps.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isAccessibilityGranted {
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

    private var startAtLoginPermissionRow: some View {
        HStack(spacing: 16) {
            Image(systemName: "power.circle")
                .font(.system(size: 28))
                .foregroundStyle(isStartAtLoginEnabled ? .green : .orange)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text("Start at Login")
                    .font(.headline)
                Text("Required so FamilyRules starts automatically after sign-in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(startAtLoginStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isStartAtLoginEnabled {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline.weight(.semibold))
            } else {
                Button(isRegisteringStartAtLogin ? "Enabling..." : "Enable Start at Login") {
                    enableStartAtLogin()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRegisteringStartAtLogin)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func refreshPermissionState() {
        isAccessibilityGranted = AccessibilityPermission.isGranted
        isStartAtLoginEnabled = ServiceManagementBridge.isMainAppEnabled
        startAtLoginStatus = ServiceManagementBridge.registrationDescription()
    }

    private func enableStartAtLogin() {
        guard !isRegisteringStartAtLogin else { return }

        isRegisteringStartAtLogin = true
        startAtLoginError = nil

        Task { @MainActor in
            defer {
                isRegisteringStartAtLogin = false
                refreshPermissionState()
            }

            do {
                try ServiceManagementBridge.registerMainAppIfAvailable()
            } catch {
                startAtLoginError = error.localizedDescription
            }
        }
    }
}
