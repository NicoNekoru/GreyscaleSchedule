import AppKit
import Foundation

enum ControlURLCommand: Equatable {
    case set(Bool)
    init?(url: URL) {
        guard url.scheme == AppConfiguration.urlScheme, url.host == "set",
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
    init(delegate: AppDelegate) { self.delegate = delegate }
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: 0x2D2D2D2D)?.stringValue,
              let url = URL(string: value) else { return }
        delegate?.handleControlURL(url)
    }
}

/// Tests can exercise the real window and asynchronous actions without changing
/// the display, preferences, launch agents or Control Centre layout.
struct SettingsEnvironment {
    var load: () -> ScheduleSettings = { SettingsStore.load() }
    var save: (ScheduleSettings) async throws -> Void = { try await ScheduleService.install(settings: $0) }
    var read: () async throws -> Bool = { try await ControlClient.shared.read() }
    var set: (Bool) async throws -> Bool = { try await ControlClient.shared.set($0) }
    var checkSolar: () throws -> Void = { _ = try SystemSolarSchedule.read() }
    var tileAdded: () throws -> Bool = { try ControlCenterIntegration.readInstallationState() }
    var backgroundReady: () -> Bool = { LaunchAgentManager.isLoaded(label: AppConfiguration.launchAgentLabel) }
    var refreshControl: () throws -> Void = { try ControlCenterIntegration.install() }
    var repairHelper: () throws -> Void = { try ControlRequestAgent.install() }
    var terminate: () -> Void = { NSApp.terminate(nil) }
    var record: (String) -> Void = ControlDiagnostics.record
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private(set) var settingsController: SettingsWindowController?
    private(set) var state: SettingsViewState
    private let environment: SettingsEnvironment
    private var controlIntentObserver: NSObjectProtocol?
    private var statusTimer: Timer?
    private var statusTask: Task<Void, Never>?
    private var statusNeedsRefresh = false
    private var statusGeneration: UInt64 = 0
    private var solarGeneration: UInt64 = 0
    private var defaultLaunch = false
    private var busy: Bool { state.busy }

    init(environment: SettingsEnvironment = SettingsEnvironment()) {
        self.environment = environment
        state = SettingsViewState(saved: environment.load())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) == true
        environment.record("App launch default=\(defaultLaunch) active=\(NSApp.isActive) control=\(ControlIntentExecutionState.tracker.hasStarted)")
        controlIntentObserver = NotificationCenter.default.addObserver(
            forName: ControlIntentExecutionState.didFinishNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshStatus(invalidatingPending: true)
            self?.terminateAfterHeadlessControl()
        }
        scheduleUserWindowPresentation()
        if ControlIntentExecutionState.tracker.hasStarted { terminateAfterHeadlessControl() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        scheduleUserWindowPresentation()
        refreshStatus(invalidatingPending: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        environment.record("Explicit app reopen")
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
            do { _ = try await environment.set(enabled); refreshStatus(invalidatingPending: true) }
            catch {
                environment.record("URL control failed: \(error.localizedDescription)")
                if window?.isVisible == true { state.displayActionError = error.localizedDescription; render() }
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
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if window == nil { window = makeSettingsWindow() }
        // Preserve the flicker-free first frame and headless intent lifecycle.
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        environment.record("Settings window presented explicit=\(userInitiated)")
        ControlInstallationPreparation.markAppOpened()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshStatus() }
        refreshStatus()
        if state.draft.mode == .sunsetToSunrise { checkSolar() }
    }
    private func terminateAfterHeadlessControl() {
        guard window?.isVisible != true, !busy,
              let generation = ControlIntentExecutionState.tracker.idleGeneration else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard self.window?.isVisible != true, !self.busy,
                  ControlIntentExecutionState.tracker.isStillIdle(generation: generation) else { return }
            self.environment.terminate()
        }
    }

    func makeSettingsWindow() -> NSWindow {
        let controller = SettingsWindowController(state: state)
        settingsController = controller
        controller.onDraftChange = { [weak self] draft in
            guard let self, !self.busy else { return }
            let changedMode = self.state.draft.mode != draft.mode
            self.state.draft = draft; self.state.scheduleError = nil
            self.render()
            if changedMode && draft.mode == .sunsetToSunrise { self.checkSolar() }
        }
        controller.onSave = { [weak self] in self?.saveSchedule($0) }
        controller.onManual = { [weak self] in self?.setFilter($0) }
        controller.onRefreshControl = { [weak self] in self?.installControl() }
        controller.onRetryDisplay = { [weak self] in self?.repairDisplay() }
        controller.onRetrySolar = { [weak self] in self?.checkSolar() }
        controller.onRetryInstallation = { [weak self] in self?.refreshStatus() }
        controller.onRepairSchedule = { [weak self] in
            guard let self else { return }
            self.saveSchedule(self.state.saved, preserveDraft: true)
        }
        controller.onUninstall = { [weak self] in self?.uninstallApp() }
        controller.onClose = { [weak self] in self?.statusTimer?.invalidate() }
        return controller.window!
    }
    private func render() { settingsController?.render(state) }

    func refreshStatus(invalidatingPending: Bool = false) {
        guard settingsController != nil, !busy else { return }
        if invalidatingPending {
            statusGeneration &+= 1
            statusTask?.cancel(); statusTask = nil; statusNeedsRefresh = false
        }
        if statusTask != nil { statusNeedsRefresh = true; return }
        statusGeneration &+= 1
        let generation = statusGeneration
        let environment = environment
        statusTask = Task { @MainActor in
            let installation = await Task.detached {
                let tile: Result<Bool, Error>
                do { tile = .success(try environment.tileAdded()) } catch { tile = .failure(error) }
                return (tile, environment.backgroundReady(), environment.load())
            }.value
            let result: Result<Bool, Error>
            do { result = .success(try await environment.read()) }
            catch { result = .failure(error) }
            guard generation == statusGeneration else { return }
            statusTask = nil
            guard !busy else { return }
            if !state.isDirty { state.draft = installation.2 }
            state.saved = installation.2
            switch installation.0 {
            case .success(let added): state.tileAdded = added; state.tileError = nil
            case .failure(let error): state.tileAdded = nil; state.tileError = error.localizedDescription
            }
            state.backgroundReady = installation.1
            switch result {
            case .success(let actual): state.actual = actual; state.displayError = nil
            case .failure(let error): state.actual = nil; state.displayError = error.localizedDescription
            }
            render()
            if statusNeedsRefresh { statusNeedsRefresh = false; refreshStatus() }
        }
    }
    func checkSolar() {
        solarGeneration &+= 1
        let generation = solarGeneration
        let check = environment.checkSolar
        Task { @MainActor in
            let error = await Task.detached { () -> String? in
                do { try check(); return nil } catch { return error.localizedDescription }
            }.value
            guard generation == solarGeneration, state.draft.mode == .sunsetToSunrise else { return }
            state.solarAvailable = error == nil; state.solarError = error
            render()
        }
    }

    private enum Area { case schedule, display, setup }
    private func perform(area: Area, operation: @escaping () async throws -> Void,
                         completion: @escaping () -> Void = {}) {
        guard !busy else { return }
        state.busy = true; statusGeneration &+= 1
        statusTask?.cancel(); statusTask = nil; statusNeedsRefresh = false
        if area == .setup { state.setupFeedback = ""; state.setupError = nil }
        render()
        Task { @MainActor in
            do {
                try await Task.detached { try await operation() }.value
                switch area {
                case .schedule: state.scheduleError = nil
                case .display: state.displayError = nil; state.displayActionError = nil
                case .setup: state.setupError = nil
                }
            } catch {
                environment.record("Operation failed: \(error.localizedDescription)")
                switch area {
                case .schedule:
                    if error is SolarScheduleError {
                        state.solarAvailable = false; state.solarError = error.localizedDescription
                        state.scheduleError = nil
                    } else { state.scheduleError = error.localizedDescription }
                case .display: state.actual = nil; state.displayActionError = error.localizedDescription
                case .setup: state.setupError = error.localizedDescription
                }
            }
            state.busy = false
            completion()
            render()
            refreshStatus()
            terminateAfterHeadlessControl()
        }
    }
    private func saveSchedule(_ settings: ScheduleSettings, preserveDraft: Bool = false) {
        let environment = environment
        perform(area: .schedule, operation: { try await environment.save(settings) }) { [self] in
            let saved = environment.load()
            state.saved = saved
            if !preserveDraft && saved == settings { state.draft = saved }
        }
    }
    private func setFilter(_ enabled: Bool) {
        let set = environment.set
        let delegate = self
        perform(area: .display, operation: {
            let actual = try await set(enabled)
            await MainActor.run { delegate.state.actual = actual }
        })
    }
    private func installControl() {
        let install = environment.refreshControl
        let wasAdded = state.tileAdded == true
        perform(area: .setup, operation: { try install() }) { [self] in
            if state.setupError == nil { state.setupFeedback = wasAdded ? "Control Centre control refreshed." : "Control Centre control added." }
        }
    }
    private func repairDisplay() {
        let repair = environment.repairHelper
        perform(area: .display, operation: { try repair() })
    }
    private func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "Uninstall \(AppConfiguration.appName)?"
        alert.informativeText = "This turns greyscale off, removes its schedule, Control Centre control and saved settings, and moves the app to the Trash. If installed with Homebrew, its installation record remains."
        alert.addButton(withTitle: "Uninstall"); alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(area: .setup, operation: {
            try ControlRequestAgent.install()
            _ = try await ControlClient.shared.set(false)
            try ScheduleService.remove()
            try ControlCenterIntegration.remove()
            try ControlRequestAgent.remove()
            try ControlCenterIntegration.unregisterExtension()
            let manager = FileManager.default
            for url in [AppPaths.support, AppPaths.log] + AppConfiguration.extensionBundleIdentifiers.map({
                AppPaths.extensionContainer(for: $0)
            }) where manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            UserDefaults.standard.removePersistentDomain(forName: AppConfiguration.bundleIdentifier)
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
                    if let error { reply.resume(throwing: error) } else { reply.resume() }
                }
            }
            await MainActor.run { NSApp.terminate(nil) }
        })
    }
}
