import AppKit

struct SettingsViewState {
    var saved: ScheduleSettings
    var draft: ScheduleSettings
    var actual: Bool?
    var busy = false
    var tileAdded: Bool?
    var backgroundReady: Bool?
    var solarAvailable = false
    var displayError: String?
    var displayActionError: String?
    var solarError: String?
    var scheduleError: String?
    var setupError: String?
    var tileError: String?
    var setupFeedback = ""

    init(saved: ScheduleSettings) { self.saved = saved; draft = saved }
    var isDirty: Bool { saved != draft }
    var manualTarget: Bool? { actual.map { !$0 } }
    var canSave: Bool { !busy && (draft.mode != .sunsetToSunrise || solarAvailable) }
}

private final class SettingsGroup: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 10
    }
    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let modePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let startPicker = NSDatePicker()
    let endPicker = NSDatePicker()
    let saveButton = NSButton(title: "Save Schedule", target: nil, action: nil)
    let manualButton = NSButton(title: "Turn On", target: nil, action: nil)
    let displayLabel = NSTextField(labelWithString: "Checking…")
    let tileLabel = NSTextField(labelWithString: "Checking…")
    let disclosure = NSButton(title: "Setup and maintenance", target: nil, action: nil)
    let dirtyDot = NSView()
    private let backgroundLabel = SettingsWindowController.secondary("Checking background scheduling…")
    private let refreshButton = NSButton(title: "Refresh Control", target: nil, action: nil)
    private let addButton = NSButton(title: "Add Control", target: nil, action: nil)
    private let uninstallButton = NSButton(title: "Uninstall…", target: nil, action: nil)
    private let allDayLabel = SettingsWindowController.secondary("All-day schedule.")
    private let solarLabel = SettingsWindowController.secondary("On at sunset. Off at sunrise, using macOS's times.")
    private let offLabel = SettingsWindowController.secondary("Saving stops automatic changes. Greyscale stays as it is.")
    private let setupFeedback = SettingsWindowController.secondary("")
    private let scheduleErrorLabel = SettingsWindowController.secondary("")
    private let setupErrorLabel = SettingsWindowController.secondary("")
    private let displayErrorLabel = SettingsWindowController.secondary("")
    private let solarErrorLabel = SettingsWindowController.secondary("")
    private let tileErrorLabel = SettingsWindowController.secondary("")
    private let displayRetry = NSButton(title: "Retry", target: nil, action: nil)
    private let solarRetry = NSButton(title: "Retry", target: nil, action: nil)
    private let tileRetry = NSButton(title: "Retry", target: nil, action: nil)
    private let setupRetry = NSButton(title: "Retry", target: nil, action: nil)
    private let scheduleRetry = NSButton(title: "Retry", target: nil, action: nil)
    private let scheduleRepair = NSButton(title: "Set Up Scheduling", target: nil, action: nil)
    private var timeFields: NSStackView!
    private var displayRecovery: NSStackView!
    private var solarRecovery: NSStackView!
    private var tileRecovery: NSStackView!
    private var setupRecovery: NSStackView!
    private var scheduleRecovery: NSStackView!
    private var maintenance: NSStackView!
    private var root: NSStackView!
    private var state: SettingsViewState
    private var hasRendered = false

    var onDraftChange: ((ScheduleSettings) -> Void)?
    var onSave: ((ScheduleSettings) -> Void)?
    var onManual: ((Bool) -> Void)?
    var onRefreshControl: (() -> Void)?
    var onRetryDisplay: (() -> Void)?
    var onRetrySolar: (() -> Void)?
    var onRetryInstallation: (() -> Void)?
    var onRepairSchedule: (() -> Void)?
    var onUninstall: (() -> Void)?
    var onClose: (() -> Void)?

    init(state: SettingsViewState) {
        self.state = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 300),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = AppConfiguration.appName
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        render(state)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        modePicker.addItems(withTitles: ScheduleMode.allCases.map(\.title))
        modePicker.isBordered = false
        modePicker.alignment = .right
        modePicker.target = self; modePicker.action = #selector(draftChanged)
        modePicker.setAccessibilityLabel("Schedule")
        modePicker.widthAnchor.constraint(equalToConstant: 190).isActive = true
        for picker in [startPicker, endPicker] {
            picker.datePickerElements = [.hourMinute]
            picker.datePickerStyle = .textFieldAndStepper
            picker.font = .systemFont(ofSize: 13)
            picker.isContinuous = false
            picker.target = self; picker.action = #selector(draftChanged)
            picker.widthAnchor.constraint(equalToConstant: 110).isActive = true
        }
        startPicker.setAccessibilityLabel("From")
        endPicker.setAccessibilityLabel("To")
        timeFields = horizontal([label("From"), startPicker, label("to"), endPicker], spacing: 8)
        configure(saveButton, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        window?.defaultButtonCell = saveButton.cell as? NSButtonCell
        configure(manualButton, action: #selector(manual))
        configure(refreshButton, action: #selector(refreshControl))
        configure(addButton, action: #selector(refreshControl))
        configure(uninstallButton, action: #selector(uninstall))
        configure(displayRetry, action: #selector(retryDisplay))
        configure(solarRetry, action: #selector(retrySolar))
        configure(tileRetry, action: #selector(retryInstallation))
        configure(setupRetry, action: #selector(refreshControl))
        configure(scheduleRetry, action: #selector(save))
        configure(scheduleRepair, action: #selector(repairSchedule))
        dirtyDot.wantsLayer = true
        dirtyDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dirtyDot.layer?.cornerRadius = 3.5
        dirtyDot.setAccessibilityElement(false)
        NSLayoutConstraint.activate([dirtyDot.widthAnchor.constraint(equalToConstant: 7),
                                     dirtyDot.heightAnchor.constraint(equalToConstant: 7)])

        let modeRow = horizontal([label("Schedule", primary: true), spacer(), modePicker])
        let editRow = horizontal([timeFields, solarLabel, offLabel, spacer(), dirtyDot, saveButton])
        for text in [solarLabel, offLabel] { text.widthAnchor.constraint(lessThanOrEqualToConstant: 310).isActive = true }
        displayLabel.widthAnchor.constraint(equalToConstant: 85).isActive = true
        displayLabel.alignment = .right
        let manualSlot = NSView()
        manualSlot.addSubview(manualButton)
        manualButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            manualSlot.widthAnchor.constraint(equalToConstant: 80),
            manualSlot.heightAnchor.constraint(equalToConstant: manualButton.intrinsicContentSize.height),
            manualButton.leadingAnchor.constraint(equalTo: manualSlot.leadingAnchor),
            manualButton.trailingAnchor.constraint(equalTo: manualSlot.trailingAnchor),
            manualButton.centerYAnchor.constraint(equalTo: manualSlot.centerYAnchor),
        ])
        let displayRow = horizontal([label("Greyscale", primary: true), spacer(), displayLabel, manualSlot])
        displayRecovery = recovery(displayErrorLabel, button: displayRetry)
        solarRecovery = recovery(solarErrorLabel, button: solarRetry)
        scheduleRecovery = recovery(scheduleErrorLabel, button: scheduleRetry)
        let main = vertical([modeRow, separator(), editRow, allDayLabel, solarRecovery,
                             scheduleRecovery, separator(), displayRow, displayRecovery])

        tileLabel.textColor = .secondaryLabelColor
        let tileRow = horizontal([label("Control Centre", primary: true), spacer(), tileLabel, addButton])
        tileRecovery = recovery(tileErrorLabel, button: tileRetry)
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.bezelStyle = .recessed
        disclosure.isBordered = false
        disclosure.font = .systemFont(ofSize: 14, weight: .medium)
        disclosure.alignment = .left
        disclosure.imagePosition = .imageTrailing
        disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        disclosure.target = self; disclosure.action = #selector(toggleMaintenance)
        let titleRow = disclosure

        let controlRow = horizontal([label("Control Centre"), spacer(), refreshButton])
        let removeRow = horizontal([Self.secondary("Remove the app and its settings"), spacer(), uninstallButton])
        setupRecovery = recovery(setupErrorLabel, button: setupRetry)
        maintenance = vertical([backgroundLabel, scheduleRepair, controlRow, setupFeedback,
                                setupRecovery, separator(), removeRow])
        maintenance.setCustomSpacing(16, after: backgroundLabel)
        let setup = vertical([tileRow, tileRecovery, separator(), titleRow, maintenance])
        setup.setCustomSpacing(4, after: titleRow)
        root = vertical([SettingsGroup(content: main), SettingsGroup(content: setup)], spacing: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = window!.contentView!
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    func render(_ state: SettingsViewState) {
        // A background status reply must not reset an in-progress time edit.
        if !hasRendered || self.state.draft != state.draft {
            modePicker.selectItem(at: ScheduleMode.allCases.firstIndex(of: state.draft.mode)!)
            startPicker.dateValue = pickerDate(state.draft.start)
            endPicker.dateValue = pickerDate(state.draft.end)
        }
        self.state = state; hasRendered = true
        modePicker.isEnabled = !state.busy
        startPicker.isEnabled = !state.busy; endPicker.isEnabled = !state.busy
        timeFields.isHidden = state.draft.mode != .custom
        solarLabel.isHidden = state.draft.mode != .sunsetToSunrise
        offLabel.isHidden = state.draft.mode != .off
        allDayLabel.isHidden = state.draft.mode != .custom || state.draft.start != state.draft.end
        dirtyDot.alphaValue = state.isDirty ? 1 : 0
        saveButton.isEnabled = state.canSave
        saveButton.setAccessibilityLabel(state.isDirty ? "Save Schedule, unsaved changes" : "Save Schedule")
        saveButton.toolTip = state.isDirty ? "Unsaved changes. The saved schedule is still active." : nil
        displayLabel.stringValue = state.actual.map { $0 ? "On" : "Off" } ?? (state.displayError == nil && state.displayActionError == nil ? "Checking…" : "Unavailable")
        manualButton.title = state.actual == true ? "Turn Off" : "Turn On"
        manualButton.isEnabled = state.actual != nil && !state.busy
        manualButton.isHidden = state.actual == nil
        tileLabel.stringValue = state.tileAdded.map { $0 ? "Added" : "Not added" } ?? (state.tileError == nil ? "Checking…" : "Unavailable")
        addButton.isHidden = state.tileAdded != false
        refreshButton.title = state.tileAdded == false ? "Add Control" : "Refresh Control"
        backgroundLabel.stringValue = !state.saved.enabled ? "Background scheduling is off." : state.backgroundReady.map { $0 ? "Background scheduling is ready." : "Background scheduling isn't set up." } ?? "Checking background scheduling…"
        scheduleRepair.isHidden = !state.saved.enabled || state.backgroundReady != false
        setupFeedback.stringValue = state.setupFeedback
        setupFeedback.isHidden = state.setupFeedback.isEmpty
        setRecovery(displayRecovery, label: displayErrorLabel, message: state.displayError ?? state.displayActionError)
        setRecovery(solarRecovery, label: solarErrorLabel, message: state.draft.mode == .sunsetToSunrise ? state.solarError : nil)
        setRecovery(scheduleRecovery, label: scheduleErrorLabel, message: state.scheduleError)
        setRecovery(setupRecovery, label: setupErrorLabel, message: state.setupError)
        setRecovery(tileRecovery, label: tileErrorLabel, message: state.tileError)
        for button in [refreshButton, addButton, uninstallButton, displayRetry, solarRetry, tileRetry, setupRetry, scheduleRetry, scheduleRepair] {
            button.isEnabled = !state.busy
        }
        maintenance.isHidden = disclosure.state != .on
        disclosure.image = NSImage(systemSymbolName: disclosure.state == .on ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        resizeToFit()
    }

    private func resizeToFit() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let height = ceil(root.fittingSize.height + 40)
        let size = NSSize(width: 540, height: height)
        if window.contentView!.bounds.size != size {
            let top = window.frame.maxY
            window.setContentSize(size)
            var frame = window.frame
            frame.origin.y = top - frame.height
            window.setFrame(frame, display: window.isVisible)
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }
    private func setRecovery(_ row: NSView, label: NSTextField, message: String?) {
        label.stringValue = message ?? ""
        row.isHidden = message == nil
    }
    var draftSettings: ScheduleSettings {
        ScheduleSettings(mode: ScheduleMode.allCases[modePicker.indexOfSelectedItem],
            start: time(startPicker), end: time(endPicker))
    }
    @objc private func draftChanged() { onDraftChange?(draftSettings) }
    @objc private func save() {
        window?.makeFirstResponder(nil)
        let draft = draftSettings
        onDraftChange?(draft)
        onSave?(draft)
    }
    @objc private func manual() { if let desired = state.manualTarget { onManual?(desired) } }
    @objc private func refreshControl() { onRefreshControl?() }
    @objc private func retryDisplay() { onRetryDisplay?() }
    @objc private func retrySolar() { onRetrySolar?() }
    @objc private func retryInstallation() { onRetryInstallation?() }
    @objc private func repairSchedule() { onRepairSchedule?() }
    @objc private func uninstall() { onUninstall?() }
    @objc private func toggleMaintenance() {
        render(state)
    }
    func windowWillClose(_ notification: Notification) { onClose?() }

    private func configure(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded; button.controlSize = .small
        button.font = .systemFont(ofSize: 13); button.target = self; button.action = action
    }
    private func recovery(_ text: NSTextField, button: NSButton) -> NSStackView {
        text.widthAnchor.constraint(equalToConstant: 350).isActive = true
        text.setAccessibilityRole(.staticText)
        return horizontal([text, spacer(), button])
    }
    private func horizontal(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
        return stack
    }
    private func vertical(_ views: [NSView], spacing: CGFloat = 14) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
    private func label(_ text: String, primary: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: primary ? 14 : 13, weight: primary ? .medium : .regular)
        return label
    }
    private static func secondary(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }
    private func pickerDate(_ time: TimeOfDay) -> Date {
        Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15,
            hour: time.hour, minute: time.minute)) ?? Date()
    }
    private func time(_ picker: NSDatePicker) -> TimeOfDay {
        let values = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        return TimeOfDay(hour: values.hour ?? 0, minute: values.minute ?? 0)
    }
}
