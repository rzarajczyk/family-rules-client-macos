import AppKit
import SwiftUI

struct DashboardView: View {
    private enum Tab: CaseIterable, Identifiable {
        case myDevice
        case allDevices

        var id: Self { self }

        var title: String {
            switch self {
            case .myDevice:
                return String.localized("This Device")
            case .allDevices:
                return String.localized("All My Devices")
            }
        }
    }

    @ObservedObject var appModel: AppModel
    @ObservedObject var activityMonitor: ActivityMonitor
    @ObservedObject var syncController: SyncController
    @ObservedObject var lifecycleController: LifecycleController
    @ObservedObject var allDevicesModel: AllDevicesModel
    let onOpenDiagnostics: () -> Void
    let onOpenSetup: () -> Void
    let onPingHelper: () -> Void
    let onTestSwitchUser: () -> Void
    let onTestLockScreen: () -> Void
    let onTestBlockRestrictedApps: () -> Void
    let onFixPermissions: () -> Void
    let onUnregister: () -> Void
    #if DEBUG
    let onDebugQuit: (() -> Void)?
    #else
    let onDebugQuit: (() -> Void)? = nil
    #endif

    @State private var refreshTick = 0
    @State private var selectedTab: Tab = .myDevice
    @State private var accessibilityGranted: Bool = AccessibilityPermission.isGranted

    private let appIconImage = AppIconImage.load()

    private var shouldUseAlertStyling: Bool {
        appModel.isRegistered && lifecycleController.lastObservedDeviceState != "ACTIVE"
    }

    private var screenTimePanelGradientColors: [Color] {
        if shouldUseAlertStyling {
            return [
                Color(red: 0.64, green: 0.14, blue: 0.22),
                Color(red: 0.88, green: 0.22, blue: 0.18)
            ]
        }

        return [
            Color(red: 0.16, green: 0.50, blue: 0.93),
            Color(red: 0.10, green: 0.27, blue: 0.71)
        ]
    }

    var body: some View {
        let snapshot = activityMonitor.snapshot()

        VStack(alignment: .leading, spacing: 14) {
            screenTimePanel(snapshot: snapshot)

            if !accessibilityGranted {
                permissionsBanner
            }

            Picker("Dashboard Section", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch selectedTab {
                case .myDevice:
                    ScrollView {
                        appUsagePanel(
                            focusedUsage: snapshot.applications,
                            visibleUsage: snapshot.visibleApplications,
                            knownApps: snapshot.knownApps
                        )
                    }
                case .allDevices:
                    ScrollView {
                        allDevicesPanel
                    }
                    .onAppear {
                        if allDevicesModel.groups.isEmpty && !allDevicesModel.isLoading {
                            allDevicesModel.refresh(registration: appModel.registration)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 620)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refreshTick += 1
            if !accessibilityGranted {
                accessibilityGranted = AccessibilityPermission.isGranted
            }
        }
    }

    private var permissionsBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission missing")
                    .font(.subheadline.weight(.semibold))
                Text("App blocking won't work without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Fix Missing Permissions") {
                onFixPermissions()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(14)
        .background(Color.orange.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func screenTimePanel(snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                HStack(alignment: .center, spacing: 16) {
                    if let appIconImage {
                        Image(nsImage: appIconImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("FamilyRules")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.85))

                        if let registration = appModel.registration {
                            Text("\(registration.instanceName)")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        } else {
                            Text("This Mac is not registered yet")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                }

                Spacer()

                Menu {
                    Button("Open Diagnostics", action: onOpenDiagnostics)
                    Button("Open Setup", action: onOpenSetup)
                    Button("Ping Helper", action: onPingHelper)
                    Divider()
                    Button("Test Switch User (30s)", action: onTestSwitchUser)
                    Button(String.localized("Test Lock Screen (30s)"), action: onTestLockScreen)
                    Button("Test Block Restricted Apps (30s)", action: onTestBlockRestrictedApps)
                    Divider()
                    Button("Unregister This Mac", role: .destructive, action: onUnregister)
                    if let onDebugQuit {
                        Divider()
                        Button("Quit (Debug)", action: onDebugQuit)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(formatDuration(snapshot.screenTimeSeconds))
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }

            if let error = syncController.lastErrorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.92))
            } else if let summary = statusSummary(snapshot: snapshot) {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: screenTimePanelGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func statusSummary(snapshot: UsageSnapshot) -> String? {
        if let countdown = lifecycleController.countdownPresentation {
            return "\(countdown.title) in \(countdown.secondsRemaining)s."
        }

        if lifecycleController.lastObservedDeviceState != "ACTIVE" {
            return "Server state: \(lifecycleController.statusDescription)."
        }

        if snapshot.isEligibleForReporting {
            return nil
        }

        return String.localized("Monitoring is paused while the session is inactive.")
    }

    private func appUsagePanel(
        focusedUsage: [String: Int],
        visibleUsage: [String: Int],
        knownApps: [String: KnownAppInfo]
    ) -> some View {
        let combinedUsage = combinedUsageEntries(focusedUsage: focusedUsage, visibleUsage: visibleUsage)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apps")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                }

                Spacer()

                Text("\(combinedUsage.count)")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .selectedContentBackgroundColor).opacity(0.16))
                    .clipShape(Capsule())
            }

            if combinedUsage.isEmpty {
                Text("No usage recorded yet")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(combinedUsage, id: \.identifier) { entry in
                        appListRow(
                            info: knownApps[entry.identifier],
                            identifier: entry.identifier,
                            focusedSeconds: entry.focusedSeconds,
                            visibleSeconds: entry.visibleSeconds
                        )
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

    private func appListRow(
        info: KnownAppInfo?,
        identifier: String,
        focusedSeconds: Int,
        visibleSeconds: Int
    ) -> some View {
        HStack(spacing: 14) {
            appIcon(for: identifier)

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info?.name ?? identifier)
                        .font(.headline.weight(.semibold))
                    Text(identifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

            }

            Spacer(minLength: 12)

            HStack(spacing: 18) {
                timeValue(title: String.localized("Focused"), seconds: focusedSeconds)
                timeValue(title: String.localized("Visible"), seconds: visibleSeconds)
            }
            .frame(alignment: .trailing)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func timeValue(title: String, seconds: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(formatDuration(seconds))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(minWidth: 84, alignment: .trailing)
    }

    private var allDevicesPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("All My Devices")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    Text("Usage groups from the server across every managed device.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(allDevicesModel.isLoading ? "Refreshing..." : "Refresh") {
                    allDevicesModel.refresh(registration: appModel.registration)
                }
                .disabled(allDevicesModel.isLoading)
            }

            if let registration = appModel.registration {
                Text("Signed in as \(registration.username) on \(registration.serverURL)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                chip(title: "Groups", value: "\(allDevicesModel.groups.count)")
                chip(title: "Last Updated", value: allDevicesModel.lastUpdatedDescription)
            }

            if let errorMessage = allDevicesModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            if allDevicesModel.groups.isEmpty, allDevicesModel.errorMessage == nil, !allDevicesModel.isLoading {
                Text("No device groups were returned yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(allDevicesModel.groups.enumerated()), id: \.offset) { _, group in
                    allDevicesGroupCard(group)
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

    private func allDevicesGroupCard(_ group: DeviceUsageGroupPayload) -> some View {
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
                        HStack(spacing: 14) {
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
                }
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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

    private func appIcon(for identifier: String) -> some View {
        Group {
            if let image = applicationImage(for: identifier) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.white)
                    .padding(10)
                    .background(Color(red: 0.31, green: 0.45, blue: 0.93))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func combinedUsageEntries(
        focusedUsage: [String: Int],
        visibleUsage: [String: Int]
    ) -> [(identifier: String, focusedSeconds: Int, visibleSeconds: Int)] {
        let identifiers = Set(focusedUsage.keys).union(visibleUsage.keys)

        return identifiers
            .map {
                (
                    identifier: $0,
                    focusedSeconds: focusedUsage[$0, default: 0],
                    visibleSeconds: visibleUsage[$0, default: 0]
                )
            }
            .sorted {
                let lhsTotal = max($0.visibleSeconds, $0.focusedSeconds)
                let rhsTotal = max($1.visibleSeconds, $1.focusedSeconds)

                if lhsTotal == rhsTotal {
                    return $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending
                }

                return lhsTotal > rhsTotal
            }
    }

    private func applicationImage(for identifier: String) -> NSImage? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }

        return nil
    }

    private func formatDuration(_ seconds: Int) -> String {
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
