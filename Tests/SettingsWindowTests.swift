import AppKit
import XCTest
@testable import GreyscaleCore

final class SettingsWindowTests: XCTestCase {
    private func workingState() -> SettingsViewState {
        var state = SettingsViewState(saved: .standard)
        state.actual = true; state.tileAdded = true; state.backgroundReady = true
        return state
    }
    private func frames(_ controller: SettingsWindowController) -> [NSRect] {
        [controller.modePicker, controller.startPicker, controller.endPicker,
         controller.saveButton, controller.manualButton, controller.disclosure].map {
            $0.convert($0.bounds, to: controller.window!.contentView!)
        }
    }
    func testFirstFrameIsLaidOutBeforeWindowBecomesVisible() {
        _ = NSApplication.shared
        let controller = SettingsWindowController(state: workingState())
        let window = controller.window!
        defer { window.orderOut(nil) }
        XCTAssertFalse(window.isVisible)
        for frame in frames(controller) {
            XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
            XCTAssertGreaterThan(frame.minX, 0); XCTAssertGreaterThan(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxX, window.contentView!.bounds.maxX)
        }
        XCTAssertFalse(window.contentView!.needsLayout)
        XCTAssertEqual(controller.modePicker.itemTitles, ["Off", "Custom", "Sunset to Sunrise"])
    }
    func testStatusReplyDoesNotMoveControlsOrResizeWindow() {
        _ = NSApplication.shared
        var state = SettingsViewState(saved: .standard)
        let controller = SettingsWindowController(state: state)
        let windowFrame = controller.window!.frame
        let initial = frames(controller)
        XCTAssertEqual(controller.displayLabel.stringValue, "Checking…")
        XCTAssertFalse(controller.manualButton.isEnabled)
        for actual in [true, false, true] {
            state.actual = actual; state.tileAdded = true; state.backgroundReady = true
            controller.render(state)
            XCTAssertEqual(controller.window!.frame, windowFrame)
            XCTAssertEqual(frames(controller), initial)
            XCTAssertEqual(controller.manualButton.title, actual ? "Turn Off" : "Turn On")
        }
        XCTAssertFalse(controller.window!.isVisible)
    }
    func testDirtyAndSaveStateNeverShiftsTheWindow() {
        _ = NSApplication.shared
        var state = workingState()
        let controller = SettingsWindowController(state: state)
        let original = frames(controller)
        let size = controller.window!.frame
        state.draft.start = TimeOfDay(hour: 21, minute: 0)
        controller.render(state)
        XCTAssertEqual(controller.dirtyDot.alphaValue, 1)
        XCTAssertEqual(frames(controller), original)
        XCTAssertEqual(controller.window!.frame, size)
        state.saved = state.draft
        controller.render(state)
        XCTAssertEqual(controller.dirtyDot.alphaValue, 0)
        XCTAssertEqual(frames(controller), original)
        XCTAssertTrue(controller.saveButton.isEnabled, "Unchanged Save still reapplies the schedule")
    }
    func testFromToAndSaveShareOneLine() {
        _ = NSApplication.shared
        let controller = SettingsWindowController(state: workingState())
        let positions = frames(controller)
        XCTAssertEqual(positions[1].midY, positions[2].midY, accuracy: 1)
        let saveAlignment = controller.saveButton.alignmentRect(forFrame: controller.saveButton.frame)
        let saveInContent = controller.saveButton.superview!.convert(saveAlignment, to: controller.window!.contentView!)
        // Native button and date-picker bezels use different optical insets.
        XCTAssertEqual(positions[1].midY, saveInContent.midY, accuracy: 3)
        XCTAssertLessThan(positions[2].maxX, positions[3].minX)
    }
    func testAnUncommittedTimeEditSurvivesAStatusReply() {
        _ = NSApplication.shared
        var state = workingState()
        let controller = SettingsWindowController(state: state)
        controller.startPicker.dateValue = Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: 21))!
        state.actual = false
        controller.render(state)
        XCTAssertEqual(controller.draftSettings.start.hour, 21)
    }
    func testUnknownStateIsUnavailableAndCannotToggle() {
        _ = NSApplication.shared
        var state = workingState()
        let controller = SettingsWindowController(state: state)
        state.actual = nil; state.displayError = "Fake display failure"
        controller.render(state)
        XCTAssertEqual(controller.displayLabel.stringValue, "Unavailable")
        XCTAssertFalse(controller.manualButton.isEnabled)
        XCTAssertNil(state.manualTarget)
        XCTAssertFalse(controller.window!.isVisible)
    }
    func testSolarAvailabilityAndBusyStateGuardSavingAndEdits() {
        _ = NSApplication.shared
        var state = workingState(); state.draft.mode = .sunsetToSunrise
        let controller = SettingsWindowController(state: state)
        XCTAssertFalse(controller.saveButton.isEnabled)
        state.solarAvailable = true
        controller.render(state)
        XCTAssertTrue(controller.saveButton.isEnabled)
        state.busy = true
        controller.render(state)
        XCTAssertFalse(controller.modePicker.isEnabled)
        XCTAssertFalse(controller.startPicker.isEnabled)
        XCTAssertFalse(controller.saveButton.isEnabled)
        XCTAssertFalse(controller.manualButton.isEnabled)
    }
    func testSingleManualButtonSendsExplicitDesiredState() {
        _ = NSApplication.shared
        var state = workingState()
        let controller = SettingsWindowController(state: state)
        var requested: [Bool] = []
        controller.onManual = { requested.append($0) }
        controller.manualButton.performClick(nil)
        state.actual = false; controller.render(state)
        controller.manualButton.performClick(nil)
        XCTAssertEqual(requested, [false, true])
    }
    func testNativeAppearanceSnapshotsWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["GREYSCALE_UI_SNAPSHOT_DIR"] else { return }
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var state = workingState()
            let controller = SettingsWindowController(state: state)
            controller.disclosure.state = .on
            for mode in ScheduleMode.allCases {
                state.draft.mode = mode; state.solarAvailable = true
                controller.render(state)
                let content = controller.window!.contentView!
                content.appearance = NSAppearance(named: appearance)
                content.displayIfNeeded()
                let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: url.appendingPathComponent("\(appearance.rawValue)-\(mode.rawValue).png"))
            }
        }
    }
}
