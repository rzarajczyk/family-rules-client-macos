import AppKit
import CoreGraphics
import Foundation

struct KnownAppInfo: Equatable, Sendable {
    let identifier: String
    let name: String
}

/// Snapshot of accumulated usage at a point in time.
struct UsageSnapshot: Equatable {
    /// Total screen-on time today (screen awake + session active), in seconds.
    let screenTimeSeconds: Int
    /// Foreground (frontmost) app usage today, keyed by app identifier, in seconds.
    let applications: [String: Int]
    /// Current frontmost app identifier, if any (and eligible for reporting).
    let activeApps: Set<String>
    /// Visible-app usage today (all apps with at least one visible non-minimized window), in seconds.
    let visibleApplications: [String: Int]
    /// Apps currently visible (at least one visible non-minimized window), if eligible.
    let visibleApps: Set<String>
    /// All apps ever seen (foreground or visible) since last daily reset.
    let knownApps: [String: KnownAppInfo]
    /// True when screen is awake and session is active.
    let isEligibleForReporting: Bool
}

@MainActor
protocol ActivityMonitorProtocol: AnyObject {
    var onKnownAppsChanged: (() -> Void)? { get set }
    func start()
    func stop()
    func snapshot() -> UsageSnapshot
}

// MARK: - UsageAccumulator

/// Pure-logic value type that accumulates foreground and visible-app usage with daily reset.
struct UsageAccumulator {
    private(set) var screenTimeSeconds: TimeInterval = 0
    /// Foreground usage per app identifier, in seconds.
    private(set) var applicationUsageSeconds: [String: TimeInterval] = [:]
    /// Visible-app usage per app identifier, in seconds.
    private(set) var visibleApplicationUsageSeconds: [String: TimeInterval] = [:]
    private(set) var knownApps: [String: KnownAppInfo] = [:]

    private var currentApp: KnownAppInfo?
    /// Currently visible app identifiers (apps with at least one visible non-minimized window).
    private var currentlyVisibleAppIDs: Set<String> = []
    private var isScreenAwake: Bool
    private var isSessionActive: Bool
    private var lastUpdatedAt: Date
    private let calendar: Calendar

    init(
        now: Date,
        calendar: Calendar = .current,
        currentApp: KnownAppInfo? = nil,
        isScreenAwake: Bool = true,
        isSessionActive: Bool = true
    ) {
        self.calendar = calendar
        self.currentApp = currentApp
        self.isScreenAwake = isScreenAwake
        self.isSessionActive = isSessionActive
        self.lastUpdatedAt = now

        if let currentApp {
            knownApps[currentApp.identifier] = currentApp
        }
    }

    var currentAppName: String {
        currentApp?.name ?? "None"
    }

    var screenAwake: Bool { isScreenAwake }
    var sessionActive: Bool { isSessionActive }

    mutating func setFrontmostApp(_ app: KnownAppInfo?, at date: Date) {
        advance(to: date)
        currentApp = app

        if let app {
            knownApps[app.identifier] = app
        }
    }

    mutating func setScreenAwake(_ isScreenAwake: Bool, at date: Date) {
        advance(to: date)
        self.isScreenAwake = isScreenAwake
    }

    mutating func setSessionActive(_ isSessionActive: Bool, at date: Date) {
        advance(to: date)
        self.isSessionActive = isSessionActive
    }

    /// Replace the full set of currently visible app identifiers (from reconciliation loop).
    mutating func setVisibleAppIDs(_ ids: Set<String>, knownAppLookup: [String: KnownAppInfo], at date: Date) {
        advance(to: date)
        currentlyVisibleAppIDs = ids

        for (id, info) in knownAppLookup {
            knownApps[id] = info
        }

    }

    mutating func snapshot(at date: Date) -> UsageSnapshot {
        advance(to: date)

        return UsageSnapshot(
            screenTimeSeconds: Int(screenTimeSeconds.rounded(.down)),
            applications: applicationUsageSeconds.mapValues { Int($0.rounded(.down)) },
            activeApps: isEligibleForReporting ? Set(currentApp.map { [$0.identifier] } ?? []) : [],
            visibleApplications: visibleApplicationUsageSeconds.mapValues { Int($0.rounded(.down)) },
            visibleApps: isEligibleForReporting ? currentlyVisibleAppIDs : [],
            knownApps: knownApps,
            isEligibleForReporting: isEligibleForReporting
        )
    }

    private var isEligibleForReporting: Bool {
        isScreenAwake && isSessionActive
    }

    private mutating func advance(to date: Date) {
        if date < lastUpdatedAt {
            lastUpdatedAt = date
            return
        }

        let currentDayStart = calendar.startOfDay(for: date)
        if calendar.startOfDay(for: lastUpdatedAt) != currentDayStart {
            screenTimeSeconds = 0
            applicationUsageSeconds.removeAll()
            visibleApplicationUsageSeconds.removeAll()
            lastUpdatedAt = currentDayStart
        }

        let elapsed = date.timeIntervalSince(lastUpdatedAt)
        guard elapsed > 0 else {
            lastUpdatedAt = date
            return
        }

        if isEligibleForReporting {
            screenTimeSeconds += elapsed

            if let currentApp {
                applicationUsageSeconds[currentApp.identifier, default: 0] += elapsed
            }

            for id in currentlyVisibleAppIDs {
                visibleApplicationUsageSeconds[id, default: 0] += elapsed
            }
        }

        lastUpdatedAt = date
    }
}

// MARK: - ActivityMonitor

@MainActor
final class ActivityMonitor: ObservableObject, ActivityMonitorProtocol {
    @Published private(set) var frontmostApplicationName: String
    @Published private(set) var isScreenAwake: Bool
    @Published private(set) var isSessionActive: Bool
    @Published private(set) var visibleAppCount: Int = 0

    var onKnownAppsChanged: (() -> Void)?

    private let workspace: NSWorkspace
    private let clock: () -> Date
    /// Overridable window lister for testability; defaults to CGWindowListCopyWindowInfo.
    private let windowLister: () -> [WindowInfo]
    private var observers: [NSObjectProtocol] = []
    private var accumulator: UsageAccumulator
    private var reconciliationTask: Task<Void, Never>?

    init(
        workspace: NSWorkspace = .shared,
        clock: @escaping () -> Date = Date.init,
        windowLister: (() -> [WindowInfo])? = nil
    ) {
        self.workspace = workspace
        self.clock = clock
        self.windowLister = windowLister ?? { Self.queryVisibleWindows() }

        let initialApp = Self.knownApp(from: workspace.frontmostApplication)
        let initialAccumulator = UsageAccumulator(now: clock(), currentApp: initialApp)

        accumulator = initialAccumulator
        frontmostApplicationName = initialAccumulator.currentAppName
        isScreenAwake = initialAccumulator.screenAwake
        isSessionActive = initialAccumulator.sessionActive
    }

    func start() {
        guard observers.isEmpty else { return }

        let center = workspace.notificationCenter

        observers = [
            // Frontmost app changed
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshFrontmostApplication()
                    self?.reconcile()
                }
            },

            // App launched – reconcile actual visible windows
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            },

            // App terminated – reconcile actual visible windows
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            },

            // App unhidden – reconcile actual visible windows
            center.addObserver(
                forName: NSWorkspace.didUnhideApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            },

            // App hidden – reconcile actual visible windows
            center.addObserver(
                forName: NSWorkspace.didHideApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            },

            // Screen / session transitions
            center.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.setScreenAwake(false) }
            },
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.setScreenAwake(true) }
            },
            center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.setSessionActive(true) }
            },
            center.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.setSessionActive(false) }
            },
        ]

        refreshFrontmostApplication()
        startReconciliationLoop()
    }

    func stop() {
        guard !observers.isEmpty else { return }

        let center = workspace.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()

        reconciliationTask?.cancel()
        reconciliationTask = nil
    }

    func snapshot() -> UsageSnapshot {
        accumulator.snapshot(at: clock())
    }

    // MARK: - Reconciliation loop

    private func startReconciliationLoop() {
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                // Pause when screen/session is inactive — no window activity possible.
                if let self, self.isScreenAwake && self.isSessionActive {
                    self.reconcile()
                }

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func reconcile() {
        let windows = windowLister()
        var visibleIDs: Set<String> = []
        var lookup: [String: KnownAppInfo] = [:]

        // Map PIDs of running apps to their KnownAppInfo.
        let runningByPID: [pid_t: NSRunningApplication] = Dictionary(
            uniqueKeysWithValues: workspace.runningApplications
                .compactMap { app -> (pid_t, NSRunningApplication)? in
                    (app.processIdentifier, app)
                }
        )

        for window in windows {
            let pid = window.ownerPID
            guard let nsApp = runningByPID[pid] else { continue }
            guard let info = Self.knownApp(from: nsApp) else { continue }

            visibleIDs.insert(info.identifier)
            lookup[info.identifier] = info
        }

        let previousKnownIDs = Set(accumulator.knownApps.keys)
        accumulator.setVisibleAppIDs(visibleIDs, knownAppLookup: lookup, at: clock())
        visibleAppCount = visibleIDs.count

        if Set(accumulator.knownApps.keys) != previousKnownIDs {
            onKnownAppsChanged?()
        }
    }

    // MARK: - Event handlers

    private func refreshFrontmostApplication() {
        setFrontmostApp(Self.knownApp(from: workspace.frontmostApplication))
    }

    private func setFrontmostApp(_ app: KnownAppInfo?) {
        let previousKnownIDs = Set(accumulator.knownApps.keys)
        accumulator.setFrontmostApp(app, at: clock())
        frontmostApplicationName = accumulator.currentAppName

        if Set(accumulator.knownApps.keys) != previousKnownIDs {
            onKnownAppsChanged?()
        }
    }

    private func setScreenAwake(_ isScreenAwake: Bool) {
        accumulator.setScreenAwake(isScreenAwake, at: clock())
        self.isScreenAwake = isScreenAwake
    }

    private func setSessionActive(_ isSessionActive: Bool) {
        accumulator.setSessionActive(isSessionActive, at: clock())
        self.isSessionActive = isSessionActive
    }

    // MARK: - Helpers

    private static func knownApp(from application: NSRunningApplication?) -> KnownAppInfo? {
        guard let application else { return nil }

        let identifier = application.bundleIdentifier ?? application.bundleURL?.path
        guard let identifier, !identifier.isEmpty else { return nil }

        return KnownAppInfo(identifier: identifier, name: application.localizedName ?? identifier)
    }

    // MARK: - Window enumeration

    /// Lightweight representation of a visible window entry from CGWindowList.
    struct WindowInfo {
        let ownerPID: pid_t
    }

    /// Returns visible, non-minimized, normal-layer windows using CGWindowListCopyWindowInfo.
    /// Requires Screen Recording permission on macOS 10.15+. Returns empty if permission is not granted.
    static func queryVisibleWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return list.compactMap { dict -> WindowInfo? in
            // Only standard-layer windows (layer 0 = normal app windows).
            guard let layer = dict[kCGWindowLayer as String] as? Int, layer == 0 else { return nil }

            // Exclude minimized windows — they have a non-zero alpha or bounds below screen.
            // CGWindowListCopyWindowInfo with .optionOnScreenOnly already excludes minimized windows.

            guard let pid = dict[kCGWindowOwnerPID as String] as? pid_t else { return nil }

            return WindowInfo(ownerPID: pid)
        }
    }
}
