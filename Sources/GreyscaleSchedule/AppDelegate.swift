import AppKit
import Foundation

enum ControlURLCommand: Equatable {
    case set(Bool)

    init?(url: URL) {
        guard url.scheme == AppConfiguration.urlScheme,
              url.host == "set",
              url.query == nil, url.fragment == nil else { return nil }
        switch url.path {
        case "/on": self = .set(true)
        case "/off": self = .set(false)
        default: return nil
        }
    }
}

final class URLCommandHandler: NSObject {
    weak var delegate: AppDelegate?

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    @objc func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let value = event.paramDescriptor(forKeyword: 0x2D2D2D2D)?.stringValue,
              let url = URL(string: value) else { return }
        delegate?.handleControlURL(url)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var controlIntentObserver: NSObjectProtocol?
    private var busy = false
    private var buttons: [NSButton] = []
    private var statusGeneration: UInt64 = 0
    private var defaultLaunch = false
    private let enabledCheck = NSButton(
        checkboxWithTitle: "Enable automatic greyscale", target: nil, action: nil
    )
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let statusLabel = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) == true
        ControlDiagnostics.record("App launch default=\(defaultLaunch) active=\(NSApp.isActive) control=\(ControlIntentExecutionState.tracker.hasStarted)")
        controlIntentObserver = NotificationCenter.default.addObserver(
            forName: ControlIntentExecutionState.didFinishNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshStatus()
            self?.terminateAfterHeadlessControl()
        }
        scheduleUserWindowPresentation()
        if ControlIntentExecutionState.tracker.hasStarted { terminateAfterHeadlessControl() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        scheduleUserWindowPresentation()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        ControlDiagnostics.record("Explicit app reopen")
        presentSettingsWindow(userInitiated: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !busy && ControlIntentExecutionState.tracker.activeCount == 0
    }

    func handleControlURL(_ url: URL) {
        guard case .set(let enabled) = ControlURLCommand(url: url) else { return }
        let ticket = ControlIntentExecutionState.begin()
        Task { @MainActor in
            defer { ControlIntentExecutionState.finish(ticket) }
            do { try await ControlClient.shared.set(enabled); refreshStatus() }
            catch {
                ControlDiagnostics.record("URL control failed: \(error.localizedDescription)")
                if window?.isVisible == true { NSApp.presentError(error) }
            }
        }
    }

    private func scheduleUserWindowPresentation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.presentSettingsWindow(userInitiated: false)
        }
    }

    private func presentSettingsWindow(userInitiated: Bool) {
        guard userInitiated || window?.isVisible != true else { return }
        guard ControlIntentExecutionState.tracker.shouldPresentWindow(
            explicit: userInitiated, defaultLaunch: defaultLaunch
        ) else { return }

        NSApp.setActivationPolicy(.regular)
        if window == nil {
            buildWindow()
            loadSettings()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ControlDiagnostics.record("Settings window presented explicit=\(userInitiated)")
        ControlInstallationPreparation.markAppOpened()
        refreshStatus()
    }

    private func terminateAfterHeadlessControl() {
        guard window?.isVisible != true, !busy,
              let generation = ControlIntentExecutionState.tracker.idleGeneration else { return }
        // Allow App Intents to deliver its result before retiring a headless app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard self.window?.isVisible != true, !self.busy,
                  ControlIntentExecutionState.tracker.isStillIdle(generation: generation) else { return }
            NSApp.terminate(nil)
        }
    }

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppConfiguration.appName
        window.center()
        self.window = window

        let title = NSTextField(labelWithString: AppConfiguration.appName)
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = secondaryLabel(
            "Automatically use greyscale overnight, with a native one-click Control Centre toggle."
        )

        enabledCheck.target = self
        enabledCheck.action = #selector(enabledChanged)
        configureTimePicker(startPicker)
        configureTimePicker(endPicker)

        let timeRow = horizontalStack([
            NSTextField(labelWithString: "From"),
            startPicker,
            NSTextField(labelWithString: "to"),
            endPicker,
        ])

        let save = NSButton(
            title: "Save Schedule", target: self, action: #selector(saveSchedule)
        )
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let on = NSButton(title: "Turn On Now", target: self, action: #selector(turnOn))
        let off = NSButton(title: "Turn Off Now", target: self, action: #selector(turnOff))
        let actions = horizontalStack([save, on, off])

        let separator = NSBox()
        separator.boxType = .separator
        let controlTitle = NSTextField(labelWithString: "Control Centre")
        controlTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let controlDescription = secondaryLabel(
            "The signed Greyscale control toggles the same display filter as Turn On Now and Turn Off Now."
        )
        let installControl = NSButton(
            title: "Install / Refresh Control",
            target: self,
            action: #selector(installControl)
        )

        statusLabel.textColor = .secondaryLabelColor
        let uninstall = NSButton(
            title: "Uninstall…", target: self, action: #selector(uninstallApp)
        )
        uninstall.bezelStyle = .rounded
        buttons = [save, on, off, installControl, uninstall]

        let stack = NSStackView(views: [
            title,
            subtitle,
            enabledCheck,
            timeRow,
            actions,
            separator,
            controlTitle,
            controlDescription,
            installControl,
            statusLabel,
            uninstall,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            subtitle.widthAnchor.constraint(equalToConstant: 432),
            controlDescription.widthAnchor.constraint(equalToConstant: 432),
        ])
    }

    private func horizontalStack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func configureTimePicker(_ picker: NSDatePicker) {
        picker.datePickerElements = [.hourMinute]
        picker.datePickerStyle = .textFieldAndStepper
    }

    private func pickerDate(for time: TimeOfDay) -> Date {
        Calendar.current.date(bySettingHour: time.hour, minute: time.minute,
                              second: 0, of: Date()) ?? Date()
    }

    private func time(from picker: NSDatePicker, fallback: TimeOfDay) -> TimeOfDay {
        let components = Calendar.current.dateComponents(
            [.hour, .minute], from: picker.dateValue
        )
        return TimeOfDay(
            hour: components.hour ?? fallback.hour,
            minute: components.minute ?? fallback.minute
        )
    }

    private func loadSettings() {
        let settings = SettingsStore.load()
        enabledCheck.state = settings.enabled ? .on : .off
        startPicker.dateValue = pickerDate(for: settings.start)
        endPicker.dateValue = pickerDate(for: settings.end)
        enabledChanged()
    }

    private var currentSettings: ScheduleSettings {
        let fallback = ScheduleSettings.standard
        return ScheduleSettings(
            enabled: enabledCheck.state == .on,
            start: time(from: startPicker, fallback: fallback.start),
            end: time(from: endPicker, fallback: fallback.end)
        )
    }

    private func refreshStatus(_ message: String? = nil) {
        guard window?.isVisible == true else { return }
        statusGeneration &+= 1
        let generation = statusGeneration
        if let message {
            statusLabel.stringValue = message
            return
        }
        Task { @MainActor in
            do {
                let actual = try await ControlClient.shared.read()
                guard generation == statusGeneration, !busy else { return }
                let control = ControlCenterIntegration.isInstalled ? "installed" : "not installed"
                statusLabel.stringValue = "Greyscale is \(actual ? "on" : "off") · Native control \(control)"
            } catch {
                guard generation == statusGeneration, !busy else { return }
                statusLabel.stringValue = "Greyscale state unavailable. Install / Refresh Control to repair the helper."
            }
        }
    }

    @objc private func enabledChanged() {
        let enabled = enabledCheck.state == .on
        startPicker.isEnabled = enabled
        endPicker.isEnabled = enabled
    }

    @objc private func saveSchedule() {
        let settings = currentSettings
        perform(message: settings.enabled ? "Schedule saved." : "Automation disabled. Manual greyscale is unchanged.") {
            try await ScheduleService.install(settings: settings)
        }
    }

    @objc private func turnOn() {
        setFilter(enabled: true)
    }

    @objc private func turnOff() {
        setFilter(enabled: false)
    }

    @objc private func installControl() {
        perform(message: "Native Greyscale control installed in Control Centre.") {
            try ControlCenterIntegration.install()
        }
    }

    private func setFilter(enabled: Bool) {
        perform {
            try await ControlClient.shared.set(enabled)
        }
    }

    private func perform(message: String? = nil, _ operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        buttons.forEach { $0.isEnabled = false }
        refreshStatus("Working…")
        Task { @MainActor in
            do {
                // launchctl and preference installation must not block AppKit.
                try await Task.detached { try await operation() }.value
                busy = false
                refreshStatus(message)
            } catch {
                busy = false
                refreshStatus()
                ControlDiagnostics.record("Operation failed: \(error.localizedDescription)")
                if window?.isVisible == true { NSApp.presentError(error) }
            }
            buttons.forEach { $0.isEnabled = true }
            terminateAfterHeadlessControl()
        }
    }

    @objc private func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "Uninstall \(AppConfiguration.appName)?"
        alert.informativeText = "This removes the schedule, Control Centre control, local settings, and turns greyscale off. The app will be moved to the Trash."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        perform {
            try ControlRequestAgent.install()
            try await ControlClient.shared.set(false)
            try ScheduleService.remove()
            try ControlCenterIntegration.remove()
            try ControlRequestAgent.remove()
            try ControlCenterIntegration.unregisterExtension()
            let manager = FileManager.default
            for url in [AppPaths.support, AppPaths.log] + AppConfiguration.extensionBundleIdentifiers.map({
                AppPaths.extensionContainer(for: $0)
            }) where manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
            UserDefaults.standard.removePersistentDomain(forName: AppConfiguration.bundleIdentifier)
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
                    if let error { reply.resume(throwing: error) }
                    else { reply.resume() }
                }
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
    }
}
