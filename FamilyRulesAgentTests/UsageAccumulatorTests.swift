import XCTest
@testable import FamilyRulesAgent

final class UsageAccumulatorTests: XCTestCase {

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FamilyRulesAgentTests", isDirectory: true)
        if FileManager.default.fileExists(atPath: tempRoot.path) {
            try FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Foreground accumulation

    func testAccumulatesScreenAndForegroundTimeWhileActive() {
        let start = Date(timeIntervalSince1970: 1_000)
        var accumulator = UsageAccumulator(
            now: start,
            currentApp: KnownAppInfo(identifier: "com.apple.finder", name: "Finder")
        )

        let snapshot = accumulator.snapshot(at: start.addingTimeInterval(30))

        XCTAssertEqual(snapshot.screenTimeSeconds, 30)
        XCTAssertEqual(snapshot.applications["com.apple.finder"], 30)
        XCTAssertEqual(snapshot.activeApps, ["com.apple.finder"])
    }

    func testStopsAccumulatingWhenScreenSleeps() {
        let start = Date(timeIntervalSince1970: 1_000)
        var accumulator = UsageAccumulator(
            now: start,
            currentApp: KnownAppInfo(identifier: "com.apple.finder", name: "Finder")
        )

        accumulator.setScreenAwake(false, at: start.addingTimeInterval(10))
        let snapshot = accumulator.snapshot(at: start.addingTimeInterval(40))

        XCTAssertEqual(snapshot.screenTimeSeconds, 10)
        XCTAssertEqual(snapshot.applications["com.apple.finder"], 10)
        XCTAssertTrue(snapshot.activeApps.isEmpty)
        XCTAssertFalse(snapshot.isEligibleForReporting)
    }

    func testResetsDailyCountersAtStartOfNewDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let start = Date(timeIntervalSince1970: 86_390)
        var accumulator = UsageAccumulator(
            now: start,
            calendar: calendar,
            currentApp: KnownAppInfo(identifier: "com.apple.finder", name: "Finder")
        )

        let snapshot = accumulator.snapshot(at: Date(timeIntervalSince1970: 86_460))

        XCTAssertEqual(snapshot.screenTimeSeconds, 60)
        XCTAssertEqual(snapshot.applications["com.apple.finder"], 60)
    }

    // MARK: - Visible-app accumulation

    func testAccumulatesVisibleAppTimeForCurrentApp() {
        let start = Date(timeIntervalSince1970: 1_000)
        var accumulator = UsageAccumulator(
            now: start,
            currentApp: KnownAppInfo(identifier: "com.apple.finder", name: "Finder")
        )

        accumulator.setVisibleAppIDs(["com.apple.finder"], knownAppLookup: [:], at: start)

        let snapshot = accumulator.snapshot(at: start.addingTimeInterval(20))

        XCTAssertEqual(snapshot.visibleApplications["com.apple.finder"], 20)
        XCTAssertEqual(snapshot.visibleApps, ["com.apple.finder"])
    }

    func testVisibleAppSetIncludesAdditionalVisibleApps() {
        let start = Date(timeIntervalSince1970: 1_000)
        let finder = KnownAppInfo(identifier: "com.apple.finder", name: "Finder")
        let safari = KnownAppInfo(identifier: "com.apple.safari", name: "Safari")
        var accumulator = UsageAccumulator(now: start, currentApp: finder)

        accumulator.setVisibleAppIDs(
            ["com.apple.finder", "com.apple.safari"],
            knownAppLookup: ["com.apple.safari": safari],
            at: start
        )
        let snapshot = accumulator.snapshot(at: start.addingTimeInterval(10))

        XCTAssertEqual(snapshot.visibleApplications["com.apple.finder"], 10)
        XCTAssertEqual(snapshot.visibleApplications["com.apple.safari"], 10)
        XCTAssertEqual(snapshot.visibleApps, ["com.apple.finder", "com.apple.safari"])
    }

    func testVisibleAppRemovedWhenHidden() {
        let start = Date(timeIntervalSince1970: 1_000)
        let finder = KnownAppInfo(identifier: "com.apple.finder", name: "Finder")
        let safari = KnownAppInfo(identifier: "com.apple.safari", name: "Safari")
        var accumulator = UsageAccumulator(now: start, currentApp: finder)

        accumulator.setVisibleAppIDs(
            ["com.apple.finder", "com.apple.safari"],
            knownAppLookup: ["com.apple.safari": safari],
            at: start
        )
        accumulator.setVisibleAppIDs(["com.apple.finder"], knownAppLookup: [:], at: start.addingTimeInterval(5))
        let snapshot = accumulator.snapshot(at: start.addingTimeInterval(10))

        // Safari was visible for 5s, then hidden.
        XCTAssertEqual(snapshot.visibleApplications["com.apple.safari"], 5)
        XCTAssertFalse(snapshot.visibleApps.contains("com.apple.safari"))
    }

    func testVisibleAppRemovedOnTermination() {
        let start = Date(timeIntervalSince1970: 1_000)
        let finder = KnownAppInfo(identifier: "com.apple.finder", name: "Finder")
        let safari = KnownAppInfo(identifier: "com.apple.safari", name: "Safari")
        var accumulator = UsageAccumulator(now: start, currentApp: finder)

        accumulator.setVisibleAppIDs(
            ["com.apple.finder", "com.apple.safari"],
            knownAppLookup: ["com.apple.safari": safari],
            at: start
        )
        accumulator.setVisibleAppIDs(["com.apple.finder"], knownAppLookup: [:], at: start.addingTimeInterval(8))
        let snapshot = accumulator.snapshot(at: start.addingTimeInterval(15))

        XCTAssertEqual(snapshot.visibleApplications["com.apple.safari"], 8)
        XCTAssertFalse(snapshot.visibleApps.contains("com.apple.safari"))
    }

    func testSetVisibleAppIDsReplacesCurrentVisibleSet() {
        let start = Date(timeIntervalSince1970: 1_000)
        let finder = KnownAppInfo(identifier: "com.apple.finder", name: "Finder")
        let safari = KnownAppInfo(identifier: "com.apple.safari", name: "Safari")
        var accumulator = UsageAccumulator(now: start, currentApp: finder)

        // Reconciler says only Safari + Finder are visible (no Terminal etc.).
        accumulator.setVisibleAppIDs(
            ["com.apple.finder", "com.apple.safari"],
            knownAppLookup: ["com.apple.safari": safari],
            at: start
        )

        let snapshot = accumulator.snapshot(at: start.addingTimeInterval(10))

        XCTAssertEqual(snapshot.visibleApplications["com.apple.finder"], 10)
        XCTAssertEqual(snapshot.visibleApplications["com.apple.safari"], 10)
        XCTAssertEqual(snapshot.visibleApps, ["com.apple.finder", "com.apple.safari"])
    }

    func testVisibleAppTimeNotAccumulatedWhenScreenAsleep() {
        let start = Date(timeIntervalSince1970: 1_000)
        let finder = KnownAppInfo(identifier: "com.apple.finder", name: "Finder")
        let safari = KnownAppInfo(identifier: "com.apple.safari", name: "Safari")
        var accumulator = UsageAccumulator(now: start, currentApp: finder)

        accumulator.setVisibleAppIDs(
            ["com.apple.finder", "com.apple.safari"],
            knownAppLookup: ["com.apple.safari": safari],
            at: start
        )
        accumulator.setScreenAwake(false, at: start.addingTimeInterval(5))
        let snapshot = accumulator.snapshot(at: start.addingTimeInterval(15))

        XCTAssertEqual(snapshot.visibleApplications["com.apple.safari"], 5)
        // visibleApps is empty when not eligible for reporting.
        XCTAssertTrue(snapshot.visibleApps.isEmpty)
    }

    func testFrontmostAppIsNotVisibleWithoutVisibleWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        var accumulator = UsageAccumulator(
            now: start,
            currentApp: KnownAppInfo(identifier: "com.apple.finder", name: "Finder")
        )

        let snapshot = accumulator.snapshot(at: start.addingTimeInterval(10))

        XCTAssertEqual(snapshot.applications["com.apple.finder"], 10)
        XCTAssertNil(snapshot.visibleApplications["com.apple.finder"])
        XCTAssertTrue(snapshot.visibleApps.isEmpty)
    }

    func testRestoresPersistedDailyTotalsOnRestart() {
        let start = Date(timeIntervalSince1970: 1_000)
        let persistedState = PersistedUsageState(
            dayStart: Calendar.current.startOfDay(for: start),
            screenTimeSeconds: 42,
            applicationUsageSeconds: ["com.apple.finder": 15],
            visibleApplicationUsageSeconds: ["com.apple.finder": 12],
            knownApps: ["com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder")]
        )
        var accumulator = UsageAccumulator(
            now: start,
            currentApp: KnownAppInfo(identifier: "com.apple.finder", name: "Finder"),
            persistedState: persistedState
        )

        let snapshot = accumulator.snapshot(at: start.addingTimeInterval(8))

        XCTAssertEqual(snapshot.screenTimeSeconds, 50)
        XCTAssertEqual(snapshot.applications["com.apple.finder"], 23)
        XCTAssertEqual(snapshot.visibleApplications["com.apple.finder"], 20)
    }

    func testIgnoresPersistedTotalsFromPreviousDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let start = Date(timeIntervalSince1970: 172_800)
        let persistedState = PersistedUsageState(
            dayStart: Date(timeIntervalSince1970: 86_400),
            screenTimeSeconds: 120,
            applicationUsageSeconds: ["com.apple.finder": 120],
            visibleApplicationUsageSeconds: ["com.apple.finder": 120],
            knownApps: ["com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder")]
        )
        var accumulator = UsageAccumulator(
            now: start,
            calendar: calendar,
            currentApp: KnownAppInfo(identifier: "com.apple.finder", name: "Finder"),
            persistedState: persistedState
        )

        let snapshot = accumulator.snapshot(at: start.addingTimeInterval(10))

        XCTAssertEqual(snapshot.screenTimeSeconds, 10)
        XCTAssertEqual(snapshot.applications["com.apple.finder"], 10)
        XCTAssertNil(snapshot.visibleApplications["com.apple.finder"])
    }

    func testSQLiteUsageStoreRoundTripsPersistedState() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FamilyRulesAgentTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let databaseURL = tempRoot.appendingPathComponent("Usage.sqlite3")
        let store = SQLiteUsageStore(databaseURL: databaseURL)
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 10_000))
        let state = PersistedUsageState(
            dayStart: dayStart,
            screenTimeSeconds: 61,
            applicationUsageSeconds: [
                "com.apple.finder": 30,
                "com.apple.safari": 31,
            ],
            visibleApplicationUsageSeconds: [
                "com.apple.finder": 61,
            ],
            knownApps: [
                "com.apple.finder": KnownAppInfo(identifier: "com.apple.finder", name: "Finder"),
                "com.apple.safari": KnownAppInfo(identifier: "com.apple.safari", name: "Safari"),
            ]
        )

        try store.save(state)
        let loaded = try store.load(dayStart: dayStart)

        XCTAssertEqual(loaded, state)
    }
}
