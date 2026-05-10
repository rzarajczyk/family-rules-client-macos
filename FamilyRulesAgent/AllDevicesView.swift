import AppKit
import SwiftUI

@MainActor
final class AllDevicesModel: ObservableObject {
    @Published private(set) var groups: [DeviceUsageGroupPayload] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdatedDescription = "Never"
    @Published private(set) var errorMessage: String?

    private let registrationClient: any RegistrationClientProtocol
    // Cancels any in-flight refresh when a new one starts.
    private var refreshTask: Task<Void, Never>?

    init(registrationClient: any RegistrationClientProtocol = RegistrationClient()) {
        self.registrationClient = registrationClient
    }

    func refresh(registration: RegistrationRecord?) {
        guard let registration else {
            groups = []
            errorMessage = "Register this Mac before loading All My Devices."
            return
        }

        // Cancel any previous in-flight fetch before starting a new one.
        refreshTask?.cancel()
        isLoading = true
        errorMessage = nil

        refreshTask = Task {
            do {
                let payload = try await registrationClient.fetchGroupsUsageReport(registration: registration)
                guard !Task.isCancelled else { return }
                groups = payload.groups.sorted {
                    if $0.totalSeconds == $1.totalSeconds {
                        return $0.groupName.localizedCaseInsensitiveCompare($1.groupName) == .orderedAscending
                    }

                    return $0.totalSeconds > $1.totalSeconds
                }
                lastUpdatedDescription = AllDevicesModel.timeFormatter.string(from: Date())
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                DiagnosticsLogger.record(error: error, context: "Failed to load all-devices usage")
            }

            isLoading = false
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
}

// Stable identity wrapper for groups so ForEach handles duplicate names safely.
private struct IndexedGroup: Identifiable {
    let id: Int
    let group: DeviceUsageGroupPayload
}

struct AllDevicesView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var model: AllDevicesModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                groupsSection
            }
            .padding(24)
        }
        .frame(minWidth: 820, minHeight: 620)
        .onAppear {
            if model.groups.isEmpty && !model.isLoading {
                model.refresh(registration: appModel.registration)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("All My Devices")
                        .font(.system(size: 32, weight: .bold, design: .rounded))

                    Text("Usage groups from the server across every managed device.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(model.isLoading ? "Refreshing..." : "Refresh") {
                    model.refresh(registration: appModel.registration)
                }
                .disabled(model.isLoading)
            }

            if let registration = appModel.registration {
                Text("Signed in as \(registration.username) on \(registration.serverURL)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                chip(title: "Groups", value: "\(model.groups.count)")
                chip(title: "Last Updated", value: model.lastUpdatedDescription)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.groups.isEmpty, model.errorMessage == nil, !model.isLoading {
                Text("No device groups were returned yet.")
                    .foregroundStyle(.secondary)
            } else {
                // Use enumerated offset as a stable id so duplicate groupNames don't crash ForEach.
                ForEach(Array(model.groups.enumerated()).map { IndexedGroup(id: $0.offset, group: $0.element) }) { item in
                    groupCard(item.group)
                }
            }
        }
    }

    private func groupCard(_ group: DeviceUsageGroupPayload) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.groupName)
                        .font(.title3.weight(.bold))
                    Text("\(group.applications.count) app\(group.applications.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(formatDuration(group.totalSeconds))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
            }

            if group.applications.isEmpty {
                Text("No member apps in this group.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(group.applications.enumerated()), id: \.offset) { _, application in
                        appRow(application)
                    }
                }
            }
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func appRow(_ application: DeviceUsageApplicationPayload) -> some View {
        HStack(spacing: 14) {
            // Icon is decoded from base64 on the application model; fall back to a placeholder.
            iconView(image: application.decodedIcon)

            VStack(alignment: .leading, spacing: 4) {
                Text(application.appName)
                    .font(.headline.weight(.semibold))
                Text(application.deviceName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(formatDuration(application.durationSeconds))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func iconView(image: NSImage?) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "rectangle.stack.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color(red: 0.27, green: 0.43, blue: 0.82))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func chip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func formatDuration(_ seconds: Int) -> String {
        // Guard against negative values from server bugs or clock skew.
        guard seconds >= 0 else { return "0s" }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }

        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, remainingSeconds)
        }

        return "\(remainingSeconds)s"
    }
}

// MARK: - Icon decoding

extension DeviceUsageApplicationPayload {
    /// Decodes the base64 PNG icon lazily and caches the result on the heap via
    /// `NSImage`'s internal reference semantics. Decoding here rather than inside
    /// the SwiftUI view body avoids performing potentially expensive base64
    /// decoding on every render pass.
    var decodedIcon: NSImage? {
        guard let base64 = iconBase64Png,
              let data = Data(base64Encoded: base64) else {
            return nil
        }
        return NSImage(data: data)
    }
}
