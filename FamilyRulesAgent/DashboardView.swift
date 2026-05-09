import SwiftUI

struct DashboardView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var activityMonitor: ActivityMonitor
    @ObservedObject var syncController: SyncController
    @ObservedObject var lifecycleController: LifecycleController
    @State private var refreshTick = 0

    var body: some View {
        let snapshot = activityMonitor.snapshot()

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                screenTimePanel(snapshot: snapshot)
                appUsagePanel(
                    focusedUsage: snapshot.applications,
                    visibleUsage: snapshot.visibleApplications,
                    knownApps: snapshot.knownApps
                )
            }
            .padding(24)
        }
        .frame(minWidth: 760, minHeight: 620)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refreshTick += 1
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FamilyRules Dashboard")
                .font(.system(size: 32, weight: .bold, design: .rounded))

            if let registration = appModel.registration {
                Text("Monitoring \(registration.instanceName)")
                    .foregroundStyle(.secondary)
            } else {
                Text("This Mac is not registered yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func screenTimePanel(snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Today")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.85))

                    Text("Device Screen Time")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                Spacer()

                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Text(formatDuration(snapshot.screenTimeSeconds))
                .font(.system(size: 48, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            HStack(spacing: 14) {
                panelChip(title: "Foreground", value: activityMonitor.frontmostApplicationName)
                panelChip(title: "Visible", value: "\(snapshot.visibleApps.count) apps")
                panelChip(title: "Sync", value: syncController.syncStatus)
                panelChip(title: "State", value: lifecycleController.statusDescription)
            }

            if let error = syncController.lastErrorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.92))
            } else {
                Text(statusSummary(snapshot: snapshot))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.50, blue: 0.93), Color(red: 0.10, green: 0.27, blue: 0.71)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func panelChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusSummary(snapshot: UsageSnapshot) -> String {
        if let countdown = lifecycleController.countdownPresentation {
            return "\(countdown.title) in \(countdown.secondsRemaining)s."
        }

        if lifecycleController.lastObservedDeviceState != "ACTIVE" {
            return "Server state: \(lifecycleController.statusDescription)."
        }

        return snapshot.isEligibleForReporting ? "Monitoring is active right now." : "Monitoring is paused while the session is inactive."
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

                    Text("Scroll through focused and visible usage today")
                        .foregroundStyle(.secondary)
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
                ScrollView {
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
                .frame(minHeight: 320, maxHeight: 420)
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

                HStack(spacing: 18) {
                    timeValue(title: "Focused", seconds: focusedSeconds)
                    timeValue(title: "Visible", seconds: visibleSeconds)
                }
            }

            Spacer(minLength: 12)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func timeValue(title: String, seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(formatDuration(seconds))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
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
