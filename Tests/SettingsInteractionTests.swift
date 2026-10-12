import AppKit
import XCTest
@testable import GreyscaleCore

private final class FakeSettingsSystem {
    let lock = NSLock()
    var saved = ScheduleSettings.standard
    var actual = true
    var saveCount = 0
    var setValues: [Bool] = []
    var saveError: Error?
    var writeError: Error?
    var tileError: Error?
    var refreshes = 0
    var saveBeforeError = false
    var readDelay: UInt64 = 0
    var reads = 0
    var activeReads = 0
    var maxActiveReads = 0
    func environment() -> SettingsEnvironment {
        SettingsEnvironment(load: { self.lock.withLock { self.saved } }, save: { settings in
            let error = self.lock.withLock { () -> Error? in
                self.saveCount += 1
                if self.saveError == nil || self.saveBeforeError { self.saved = settings }
                return self.saveError
            }
            if let error { throw error }
        }, read: {
            let snapshot = self.lock.withLock { () -> (UInt64, Bool) in
                self.reads += 1; self.activeReads += 1
                self.maxActiveReads = max(self.maxActiveReads, self.activeReads)
                return (self.readDelay, self.actual)
            }
            defer { self.lock.withLock { self.activeReads -= 1 } }
            if snapshot.0 > 0 { try await Task.sleep(nanoseconds: snapshot.0) }
            return snapshot.1
        }, set: { desired in
            try self.lock.withLock {
                if let error = self.writeError { throw error }
                self.setValues.append(desired); self.actual = desired
                return desired
            }
        }, checkSolar: {}, tileAdded: {
            try self.lock.withLock {
                if let error = self.tileError { throw error }
                return true
            }
        }, backgroundReady: { true }, refreshControl: { self.lock.withLock { self.refreshes += 1 } },
        repairHelper: {}, terminate: {}, record: { _ in })
    }
}

final class SettingsInteractionTests: XCTestCase {
    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("The settings operation did not complete")
    }
    @MainActor func testDraftDoesNotSaveAndExplicitSaveCommitsExactlyOnce() async throws {
        _ = NSApplication.shared
        let system = FakeSettingsSystem()
        let delegate = AppDelegate(environment: system.environment())
        _ = delegate.makeSettingsWindow()
        var draft = ScheduleSettings.standard; draft.start = .init(hour: 21, minute: 15)
        delegate.settingsController!.onDraftChange?(draft)
        XCTAssertTrue(delegate.state.isDirty)
        XCTAssertEqual(system.lock.withLock { system.saveCount }, 0)
        delegate.settingsController!.onSave?(draft)
        XCTAssertTrue(delegate.state.busy)
        XCTAssertFalse(delegate.settingsController!.modePicker.isEnabled)
        try await waitUntil { !delegate.state.busy }
        XCTAssertEqual(delegate.state.saved, draft)
        XCTAssertFalse(delegate.state.isDirty)
        XCTAssertEqual(system.lock.withLock { system.saveCount }, 1)
        XCTAssertFalse(delegate.settingsController!.window!.isVisible)
    }
    @MainActor func testFailedSavePreservesDraftAndFailedApplyRecognizesPersistedSettings() async throws {
        _ = NSApplication.shared
        for persisted in [false, true] {
            let system = FakeSettingsSystem()
            system.saveError = ScheduleSaveError.displayUpdateFailed("Fake write failed")
            system.saveBeforeError = persisted
            let delegate = AppDelegate(environment: system.environment())
            _ = delegate.makeSettingsWindow()
            var draft = ScheduleSettings.standard; draft.end = .init(hour: 6, minute: 30)
            delegate.settingsController!.onDraftChange?(draft)
            delegate.settingsController!.onSave?(draft)
            try await waitUntil { !delegate.state.busy }
            XCTAssertEqual(delegate.state.draft, draft)
            XCTAssertEqual(delegate.state.saved, persisted ? draft : .standard)
            XCTAssertEqual(delegate.state.isDirty, !persisted)
            XCTAssertNotNil(delegate.state.scheduleError)
        }
    }
    @MainActor func testFailedManualWriteRemainsInlineAfterSuccessfulStatusRead() async throws {
        _ = NSApplication.shared
        let system = FakeSettingsSystem()
        system.writeError = SolarScheduleError.unavailable
        let delegate = AppDelegate(environment: system.environment())
        _ = delegate.makeSettingsWindow()
        delegate.refreshStatus()
        try await waitUntil { delegate.state.actual != nil }
        delegate.settingsController!.manualButton.performClick(nil)
        try await waitUntil { !delegate.state.busy && delegate.state.actual != nil }
        XCTAssertEqual(delegate.state.actual, true)
        XCTAssertNotNil(delegate.state.displayActionError)
        XCTAssertEqual(delegate.settingsController!.manualButton.title, "Turn Off")
    }
    @MainActor func testStatusRefreshesCoalesceInsteadOfStarvingSlowReplies() async throws {
        _ = NSApplication.shared
        let system = FakeSettingsSystem(); system.readDelay = 30_000_000
        let delegate = AppDelegate(environment: system.environment())
        _ = delegate.makeSettingsWindow()
        delegate.refreshStatus(); delegate.refreshStatus(); delegate.refreshStatus()
        try await waitUntil { delegate.state.actual != nil && system.lock.withLock { system.reads == 2 && system.activeReads == 0 } }
        XCTAssertEqual(system.lock.withLock { system.maxActiveReads }, 1)
        XCTAssertEqual(delegate.state.actual, true)
    }
    @MainActor func testLateReadCannotReplaceAConfirmedManualChange() async throws {
        _ = NSApplication.shared
        let system = FakeSettingsSystem()
        let delegate = AppDelegate(environment: system.environment())
        _ = delegate.makeSettingsWindow()
        delegate.refreshStatus()
        try await waitUntil { delegate.state.actual != nil }
        system.lock.withLock { system.readDelay = 60_000_000 }
        delegate.refreshStatus()
        delegate.settingsController!.manualButton.performClick(nil)
        try await waitUntil { !delegate.state.busy && delegate.state.actual == false }
        XCTAssertEqual(system.lock.withLock { system.setValues }, [false])
        XCTAssertEqual(delegate.settingsController!.manualButton.title, "Turn On")
    }
    @MainActor func testExternalControlRefreshInvalidatesAnOlderSnapshot() async throws {
        _ = NSApplication.shared
        let system = FakeSettingsSystem(); system.readDelay = 50_000_000
        let delegate = AppDelegate(environment: system.environment())
        _ = delegate.makeSettingsWindow()
        delegate.refreshStatus()
        try await waitUntil { system.lock.withLock { system.reads == 1 } }
        system.lock.withLock { system.actual = false }
        delegate.refreshStatus(invalidatingPending: true)
        try await waitUntil { delegate.state.actual == false }
        XCTAssertEqual(delegate.settingsController!.manualButton.title, "Turn On")
    }
    @MainActor func testURLControlDoesNotCreateASettingsWindow() async throws {
        _ = NSApplication.shared
        let system = FakeSettingsSystem()
        let delegate = AppDelegate(environment: system.environment())
        delegate.handleControlURL(AppConfiguration.filterURL(enabled: false))
        try await waitUntil { system.lock.withLock { system.setValues == [false] } }
        XCTAssertNil(delegate.settingsController)
    }
    @MainActor func testUnreadableControlLayoutIsUnavailableAndRetryDoesNotInstallATile() async throws {
        _ = NSApplication.shared
        let system = FakeSettingsSystem(); system.tileError = ControlCenterError.invalidPreferences
        let delegate = AppDelegate(environment: system.environment())
        _ = delegate.makeSettingsWindow()
        delegate.refreshStatus()
        try await waitUntil { delegate.state.tileError != nil }
        XCTAssertNil(delegate.state.tileAdded)
        XCTAssertEqual(delegate.settingsController!.tileLabel.stringValue, "Unavailable")
        delegate.settingsController!.onRetryInstallation?()
        try await waitUntil { system.lock.withLock { system.reads >= 2 } }
        XCTAssertEqual(system.lock.withLock { system.refreshes }, 0)
    }
}
