import XCTest
@testable import GreyscaleCore

final class SolarScheduleTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var properties: [String: Any] {
        ["previousSunset": date("2026-10-10T18:00:00Z"), "sunrise": date("2026-10-11T06:00:00Z"),
         "sunset": date("2026-10-11T18:00:00Z"), "nextSunrise": date("2026-10-12T06:00:00Z"),
         "nextSunset": date("2026-10-12T18:00:00Z")]
    }
    func testExactSolarBoundariesAndOvernightState() throws {
        for (time, expected) in [("2026-10-11T05:59:59Z", true), ("2026-10-11T06:00:00Z", false),
                                 ("2026-10-11T17:59:59Z", false), ("2026-10-11T18:00:00Z", true)] {
            let now = date(time)
            let snapshot = try SolarScheduleSnapshot(properties: properties, on: now)
            let settings = ScheduleSettings(mode: .sunsetToSunrise, start: .init(hour: 22, minute: 0), end: .init(hour: 5, minute: 0))
            XCTAssertEqual(settings.desiredState(on: now, solar: snapshot), expected)
            XCTAssertGreaterThan(snapshot.next.date, now)
        }
    }
    func testMissingStaleMalformedAndContradictorySunTimesFailClosed() {
        let now = date("2026-10-11T12:00:00Z")
        for bad in [[String: Any](), ["sunrise": "06:00", "sunset": "18:00"],
                    ["sunrise": date("2026-10-01T06:00:00Z"), "sunset": date("2026-10-20T18:00:00Z")],
                    ["sunrise": date("2026-10-11T06:00:00Z"), "sunset": date("2026-10-11T06:00:00Z"), "nextSunset": date("2026-10-11T18:00:00Z")]] {
            XCTAssertThrowsError(try SolarScheduleSnapshot(properties: bad, on: now))
        }
    }
    func testSolarModeHasNoFixedTimeFallbackOrPeriodicCalendarWrite() async throws {
        var settings = ScheduleSettings.standard; settings.mode = .sunsetToSunrise
        XCTAssertNil(settings.desiredState())
        do {
            try await ScheduleService.apply(settings) { _ in XCTFail("Unavailable solar data wrote the display") }
            XCTFail("Solar absence must be reported")
        } catch { XCTAssertTrue(error is SolarScheduleError) }
        let definition = ScheduleService.definition(settings: settings, executable: "/fake/app", fingerprint: "new-binary")!
        XCTAssertEqual(definition["ProgramArguments"] as? [String], ["/fake/app", "--serve-solar-schedule"])
        XCTAssertNil(definition["StartCalendarInterval"])
        XCTAssertEqual((definition["EnvironmentVariables"] as? [String: String])?["GREYSCALE_SCHEDULE_BINARY_SHA256"], "new-binary")
    }
    func testManualChoiceSurvivesPollsUntilTheNextBoundaryAndWakeCatchesUp() async throws {
        let driver = SolarScheduleDriver()
        var writes: [Bool] = []
        for time in ["2026-10-11T05:00:00Z", "2026-10-11T05:30:00Z", "2026-10-11T05:59:59Z",
                     "2026-10-11T07:00:00Z", "2026-10-11T12:00:00Z", "2026-10-11T19:00:00Z"] {
            let snapshot = try SolarScheduleSnapshot(properties: properties, on: date(time))
            try await driver.apply(snapshot) { writes.append($0) }
        }
        XCTAssertEqual(writes, [true, false, true], "Polls cannot undo a manual choice; a slept-through boundary must still apply")
    }
    func testFailedBoundaryRetriesRatherThanAcknowledgingAnUnconfirmedWrite() async throws {
        let driver = SolarScheduleDriver()
        let snapshot = try SolarScheduleSnapshot(properties: properties, on: date("2026-10-11T19:00:00Z"))
        do { try await driver.apply(snapshot) { _ in throw SolarScheduleError.unavailable } } catch {}
        var writes: [Bool] = []
        try await driver.apply(snapshot) { writes.append($0) }
        try await driver.apply(snapshot) { writes.append($0) }
        XCTAssertEqual(writes, [true])
    }
    func testRestartPreservesManualChoiceUntilARealBoundary() async throws {
        let night = try SolarScheduleSnapshot(properties: properties, on: date("2026-10-11T05:00:00Z"))
        let restarted = SolarScheduleDriver(handled: night.previous)
        var writes: [Bool] = []
        try await restarted.apply(night) { writes.append($0) }
        XCTAssertTrue(writes.isEmpty)
        let morning = try SolarScheduleSnapshot(properties: properties, on: date("2026-10-11T07:00:00Z"))
        try await restarted.apply(morning) { writes.append($0) }
        XCTAssertEqual(writes, [false])
    }
    func testSnapshotCannotBeUsedAfterItsBoundary() async throws {
        let night = try SolarScheduleSnapshot(properties: properties, on: date("2026-10-11T05:00:00Z"))
        let morning = date("2026-10-11T07:00:00Z")
        XCTAssertNil(night.desiredState(on: morning))
        var settings = ScheduleSettings.standard; settings.mode = .sunsetToSunrise
        do {
            try await ScheduleService.apply(settings, on: morning, solar: night) { _ in XCTFail("An expired snapshot changed the display") }
            XCTFail("An expired snapshot was silently accepted")
        } catch { XCTAssertTrue(error is SolarScheduleError) }
    }
    func testV2RecordMigratesWithoutLosingCustomTimesOrEnabledState() throws {
        let suite = "local.greyscale.solar-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"enabled":false,"start":{"hour":21,"minute":15},"end":{"hour":6,"minute":30}}"#.utf8), forKey: "schedule.v2")
        var settings = SettingsStore.load(from: defaults)
        XCTAssertEqual(settings.mode, .off); XCTAssertEqual(settings.start, .init(hour: 21, minute: 15))
        settings.mode = .sunsetToSunrise
        SettingsStore.save(settings, to: defaults)
        XCTAssertEqual(SettingsStore.load(from: defaults), settings)
        settings.mode = .custom
        XCTAssertEqual(settings.end, .init(hour: 6, minute: 30))
    }
}
