import AppKit
import CoreGraphics
import Foundation
import SQLite3

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

    init(
        screenTimeSeconds: Int,
        applications: [String: Int],
        activeApps: Set<String>,
        visibleApplications: [String: Int],
        visibleApps: Set<String>,
        knownApps: [String: KnownAppInfo],
        isEligibleForReporting: Bool,
    ) {
        self.screenTimeSeconds = screenTimeSeconds
        self.applications = applications
        self.activeApps = activeApps
        self.visibleApplications = visibleApplications
        self.visibleApps = visibleApps
        self.knownApps = knownApps
        self.isEligibleForReporting = isEligibleForReporting
    }
}

struct PersistedUsageState: Equatable {
    let dayStart: Date
    let screenTimeSeconds: TimeInterval
    let applicationUsageSeconds: [String: TimeInterval]
    let visibleApplicationUsageSeconds: [String: TimeInterval]
    let knownApps: [String: KnownAppInfo]
}

protocol UsageStoreProtocol {
    func load(dayStart: Date) throws -> PersistedUsageState?
    func save(_ state: PersistedUsageState) throws
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
        isSessionActive: Bool = true,
        persistedState: PersistedUsageState? = nil
    ) {
        self.calendar = calendar
        self.currentApp = currentApp
        self.isScreenAwake = isScreenAwake
        self.isSessionActive = isSessionActive
        self.lastUpdatedAt = now

        if let persistedState,
           calendar.startOfDay(for: now) == persistedState.dayStart {
            screenTimeSeconds = persistedState.screenTimeSeconds
            applicationUsageSeconds = persistedState.applicationUsageSeconds
            visibleApplicationUsageSeconds = persistedState.visibleApplicationUsageSeconds
            knownApps = persistedState.knownApps

            // On process restart, preserve visibility for the current frontmost app
            // until the next reconcile pass can rebuild the exact visible window set.
            if let currentApp,
               persistedState.visibleApplicationUsageSeconds[currentApp.identifier] != nil {
                currentlyVisibleAppIDs = [currentApp.identifier]
            }
        }

        if let currentApp {
            knownApps[currentApp.identifier] = currentApp
        }
    }

    init(
        now: Date,
        calendar: Calendar = .current,
        currentApp: KnownAppInfo? = nil,
        isScreenAwake: Bool = true,
        isSessionActive: Bool = true
    ) {
        self.init(
            now: now,
            calendar: calendar,
            currentApp: currentApp,
            isScreenAwake: isScreenAwake,
            isSessionActive: isSessionActive,
            persistedState: nil
        )
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

    mutating func persistedState(at date: Date) -> PersistedUsageState {
        advance(to: date)

        return PersistedUsageState(
            dayStart: calendar.startOfDay(for: date),
            screenTimeSeconds: screenTimeSeconds,
            applicationUsageSeconds: applicationUsageSeconds,
            visibleApplicationUsageSeconds: visibleApplicationUsageSeconds,
            knownApps: knownApps
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
            knownApps.removeAll()

            if let currentApp {
                knownApps[currentApp.identifier] = currentApp
            }

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
    private let usageStore: any UsageStoreProtocol
    /// Overridable window lister for testability; defaults to CGWindowListCopyWindowInfo.
    private let windowLister: () -> [WindowInfo]
    private var observers: [NSObjectProtocol] = []
    private var accumulator: UsageAccumulator
    private var reconciliationTask: Task<Void, Never>?

    init(
        workspace: NSWorkspace = .shared,
        clock: @escaping () -> Date = Date.init,
        windowLister: (() -> [WindowInfo])? = nil,
        usageStore: any UsageStoreProtocol = SQLiteUsageStore()
    ) {
        self.workspace = workspace
        self.clock = clock
        self.usageStore = usageStore
        self.windowLister = windowLister ?? { Self.queryVisibleWindows() }

        let now = clock()
        let initialApp = Self.knownApp(from: workspace.frontmostApplication)
        let persistedState: PersistedUsageState?

        do {
            persistedState = try usageStore.load(dayStart: Calendar.current.startOfDay(for: now))
        } catch {
            persistedState = nil
            DiagnosticsLogger.record(error: error, context: "Failed to load persisted usage state")
        }

        let initialAccumulator = UsageAccumulator(now: now, currentApp: initialApp, persistedState: persistedState)

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

        persistAccumulator(at: clock())

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
        let now = clock()
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
        accumulator.setVisibleAppIDs(visibleIDs, knownAppLookup: lookup, at: now)
        visibleAppCount = visibleIDs.count
        persistAccumulator(at: now)

        if Set(accumulator.knownApps.keys) != previousKnownIDs {
            onKnownAppsChanged?()
        }
    }

    // MARK: - Event handlers

    private func refreshFrontmostApplication() {
        setFrontmostApp(Self.knownApp(from: workspace.frontmostApplication))
    }

    private func setFrontmostApp(_ app: KnownAppInfo?) {
        let now = clock()
        let previousKnownIDs = Set(accumulator.knownApps.keys)
        accumulator.setFrontmostApp(app, at: now)
        frontmostApplicationName = accumulator.currentAppName
        persistAccumulator(at: now)

        if Set(accumulator.knownApps.keys) != previousKnownIDs {
            onKnownAppsChanged?()
        }
    }

    private func setScreenAwake(_ isScreenAwake: Bool) {
        let now = clock()
        accumulator.setScreenAwake(isScreenAwake, at: now)
        self.isScreenAwake = isScreenAwake
        persistAccumulator(at: now)
    }

    private func setSessionActive(_ isSessionActive: Bool) {
        let now = clock()
        accumulator.setSessionActive(isSessionActive, at: now)
        self.isSessionActive = isSessionActive
        persistAccumulator(at: now)
    }

    private func persistAccumulator(at date: Date) {
        do {
            try usageStore.save(accumulator.persistedState(at: date))
        } catch {
            DiagnosticsLogger.record(error: error, context: "Failed to persist usage state")
        }
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

final class SQLiteUsageStore: UsageStoreProtocol {
    private let databaseURL: URL
    private let fileManager: FileManager

    init(databaseURL: URL = AgentPersistencePaths.settingsDatabaseURL, fileManager: FileManager = .default) {
        self.databaseURL = databaseURL
        self.fileManager = fileManager
    }

    func load(dayStart: Date) throws -> PersistedUsageState? {
        try withDatabase { database in
            let dayStartEpoch = dayStart.timeIntervalSince1970
            let screenTimeSeconds = try loadScreenTime(dayStartEpoch: dayStartEpoch, database: database)
            let applicationUsageSeconds = try loadUsageMap(
                tableName: "usage_daily_foreground",
                dayStartEpoch: dayStartEpoch,
                database: database
            )
            let visibleApplicationUsageSeconds = try loadUsageMap(
                tableName: "usage_daily_visible",
                dayStartEpoch: dayStartEpoch,
                database: database
            )
            let knownApps = try loadKnownApps(dayStartEpoch: dayStartEpoch, database: database)

            guard screenTimeSeconds != nil || !applicationUsageSeconds.isEmpty || !visibleApplicationUsageSeconds.isEmpty || !knownApps.isEmpty else {
                return nil
            }

            return PersistedUsageState(
                dayStart: dayStart,
                screenTimeSeconds: screenTimeSeconds ?? 0,
                applicationUsageSeconds: applicationUsageSeconds,
                visibleApplicationUsageSeconds: visibleApplicationUsageSeconds,
                knownApps: knownApps
            )
        }
    }

    func save(_ state: PersistedUsageState) throws {
        try withDatabase { database in
            let dayStartEpoch = state.dayStart.timeIntervalSince1970
            try database.execute(sql: "BEGIN IMMEDIATE TRANSACTION")

            do {
                try upsertScreenTime(dayStartEpoch: dayStartEpoch, totalSeconds: state.screenTimeSeconds, database: database)
                try upsertUsageMap(
                    tableName: "usage_daily_foreground",
                    dayStartEpoch: dayStartEpoch,
                    values: state.applicationUsageSeconds,
                    database: database
                )
                try upsertUsageMap(
                    tableName: "usage_daily_visible",
                    dayStartEpoch: dayStartEpoch,
                    values: state.visibleApplicationUsageSeconds,
                    database: database
                )
                try upsertKnownApps(dayStartEpoch: dayStartEpoch, knownApps: state.knownApps, database: database)
                try database.execute(sql: "COMMIT TRANSACTION")
            } catch {
                try? database.execute(sql: "ROLLBACK TRANSACTION")
                throw error
            }
        }
    }

    private func loadScreenTime(dayStartEpoch: TimeInterval, database: OpaquePointer) throws -> TimeInterval? {
        var statement: OpaquePointer?
        let sql = "SELECT total_seconds FROM screen_time_daily WHERE day_start_epoch = ?"

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageStoreError.prepareFailed(message: database.errorMessage)
        }

        defer { sqlite3_finalize(statement) }
        try bind(double: dayStartEpoch, at: 1, to: statement, database: database)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_double(statement, 0)
        case SQLITE_DONE:
            return nil
        default:
            throw UsageStoreError.stepFailed(message: database.errorMessage)
        }
    }

    private func loadUsageMap(tableName: String, dayStartEpoch: TimeInterval, database: OpaquePointer) throws -> [String: TimeInterval] {
        var statement: OpaquePointer?
        let sql = "SELECT app_identifier, total_seconds FROM \(tableName) WHERE day_start_epoch = ?"

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageStoreError.prepareFailed(message: database.errorMessage)
        }

        defer { sqlite3_finalize(statement) }
        try bind(double: dayStartEpoch, at: 1, to: statement, database: database)

        var result: [String: TimeInterval] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let identifier = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else {
                continue
            }

            result[identifier] = sqlite3_column_double(statement, 1)
        }

        if sqlite3_errcode(database) != SQLITE_OK && sqlite3_errcode(database) != SQLITE_ROW && sqlite3_errcode(database) != SQLITE_DONE {
            throw UsageStoreError.stepFailed(message: database.errorMessage)
        }

        return result
    }

    private func loadKnownApps(dayStartEpoch: TimeInterval, database: OpaquePointer) throws -> [String: KnownAppInfo] {
        var statement: OpaquePointer?
        let sql = "SELECT app_identifier, app_name FROM known_apps WHERE day_start_epoch = ?"

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageStoreError.prepareFailed(message: database.errorMessage)
        }

        defer { sqlite3_finalize(statement) }
        try bind(double: dayStartEpoch, at: 1, to: statement, database: database)

        var result: [String: KnownAppInfo] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let identifier = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let name = sqlite3_column_text(statement, 1).map({ String(cString: $0) }) else {
                continue
            }

            result[identifier] = KnownAppInfo(identifier: identifier, name: name)
        }

        if sqlite3_errcode(database) != SQLITE_OK && sqlite3_errcode(database) != SQLITE_ROW && sqlite3_errcode(database) != SQLITE_DONE {
            throw UsageStoreError.stepFailed(message: database.errorMessage)
        }

        return result
    }

    private func upsertScreenTime(dayStartEpoch: TimeInterval, totalSeconds: TimeInterval, database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO screen_time_daily(day_start_epoch, total_seconds) VALUES(?, ?) ON CONFLICT(day_start_epoch) DO UPDATE SET total_seconds = excluded.total_seconds"

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageStoreError.prepareFailed(message: database.errorMessage)
        }

        defer { sqlite3_finalize(statement) }
        try bind(double: dayStartEpoch, at: 1, to: statement, database: database)
        try bind(double: totalSeconds, at: 2, to: statement, database: database)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw UsageStoreError.stepFailed(message: database.errorMessage)
        }
    }

    private func upsertUsageMap(tableName: String, dayStartEpoch: TimeInterval, values: [String: TimeInterval], database: OpaquePointer) throws {
        guard !values.isEmpty else { return }

        var statement: OpaquePointer?
        let sql = "INSERT INTO \(tableName)(day_start_epoch, app_identifier, total_seconds) VALUES(?, ?, ?) ON CONFLICT(day_start_epoch, app_identifier) DO UPDATE SET total_seconds = excluded.total_seconds"

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageStoreError.prepareFailed(message: database.errorMessage)
        }

        defer { sqlite3_finalize(statement) }

        for (identifier, totalSeconds) in values {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(double: dayStartEpoch, at: 1, to: statement, database: database)
            try bind(text: identifier, at: 2, to: statement, database: database)
            try bind(double: totalSeconds, at: 3, to: statement, database: database)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw UsageStoreError.stepFailed(message: database.errorMessage)
            }
        }
    }

    private func upsertKnownApps(dayStartEpoch: TimeInterval, knownApps: [String: KnownAppInfo], database: OpaquePointer) throws {
        guard !knownApps.isEmpty else { return }

        var statement: OpaquePointer?
        let sql = "INSERT INTO known_apps(day_start_epoch, app_identifier, app_name) VALUES(?, ?, ?) ON CONFLICT(day_start_epoch, app_identifier) DO UPDATE SET app_name = excluded.app_name"

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageStoreError.prepareFailed(message: database.errorMessage)
        }

        defer { sqlite3_finalize(statement) }

        for app in knownApps.values {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(double: dayStartEpoch, at: 1, to: statement, database: database)
            try bind(text: app.identifier, at: 2, to: statement, database: database)
            try bind(text: app.name, at: 3, to: statement, database: database)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw UsageStoreError.stepFailed(message: database.errorMessage)
            }
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try fileManager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path(percentEncoded: false), &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            throw UsageStoreError.openFailed(message: database?.errorMessage ?? "Unknown SQLite open error")
        }

        defer { sqlite3_close(database) }

        try database.execute(sql: "CREATE TABLE IF NOT EXISTS screen_time_daily (day_start_epoch REAL PRIMARY KEY NOT NULL, total_seconds REAL NOT NULL)")
        try database.execute(sql: "CREATE TABLE IF NOT EXISTS usage_daily_foreground (day_start_epoch REAL NOT NULL, app_identifier TEXT NOT NULL, total_seconds REAL NOT NULL, PRIMARY KEY(day_start_epoch, app_identifier))")
        try database.execute(sql: "CREATE TABLE IF NOT EXISTS usage_daily_visible (day_start_epoch REAL NOT NULL, app_identifier TEXT NOT NULL, total_seconds REAL NOT NULL, PRIMARY KEY(day_start_epoch, app_identifier))")
        try database.execute(sql: "CREATE TABLE IF NOT EXISTS known_apps (day_start_epoch REAL NOT NULL, app_identifier TEXT NOT NULL, app_name TEXT NOT NULL, PRIMARY KEY(day_start_epoch, app_identifier))")

        return try body(database)
    }

    private func bind(text: String, at index: Int32, to statement: OpaquePointer?, database: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw UsageStoreError.bindFailed(message: database.errorMessage)
        }
    }

    private func bind(double: Double, at index: Int32, to statement: OpaquePointer?, database: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, double) == SQLITE_OK else {
            throw UsageStoreError.bindFailed(message: database.errorMessage)
        }
    }
}

private enum UsageStoreError: LocalizedError {
    case openFailed(message: String)
    case prepareFailed(message: String)
    case bindFailed(message: String)
    case stepFailed(message: String)
    case executeFailed(message: String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(message):
            return "Failed to open the usage database: \(message)"
        case let .prepareFailed(message):
            return "Failed to prepare a usage database statement: \(message)"
        case let .bindFailed(message):
            return "Failed to bind a usage database value: \(message)"
        case let .stepFailed(message):
            return "Failed to update usage database state: \(message)"
        case let .executeFailed(message):
            return "Failed to execute a usage database statement: \(message)"
        }
    }
}

private extension OpaquePointer {
    var errorMessage: String {
        guard let cString = sqlite3_errmsg(self) else {
            return "Unknown SQLite error"
        }

        return String(cString: cString)
    }

    func execute(sql: String) throws {
        guard sqlite3_exec(self, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageStoreError.executeFailed(message: errorMessage)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
