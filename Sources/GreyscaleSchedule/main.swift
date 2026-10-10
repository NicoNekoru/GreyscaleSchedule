import AppKit
import Darwin
import Foundation

private enum CommandLineInterface {
    static func run(arguments: ArraySlice<String>) async {
        guard let command = arguments.first else { exit(64) }

        do {
            switch command {
            case "--migrate-control-identity":
                let values = Array(arguments.dropFirst())
                guard values.count == 4 else { throw ControlCenterError.invalidIdentity }
                try await ControlInstallationPreparation.perform(openApplication: openApplicationForSetup) {
                    try ControlCenterIntegration.migrateIdentity(containerIdentifier: values[0],
                        extensionIdentifier: values[1], kind: values[2], previousDisplayName: values[3])
                }
                print("migrated")
            case "--install-helper":
                try ControlRequestAgent.install()
            case "--apply-schedule":
                try await ScheduleService.applyCurrentSchedule()
            case "--on", "--request-control-on":
                try await ControlClient.shared.set(true)
            case "--off", "--request-control-off":
                try await ControlClient.shared.set(false)
            case "--status":
                print(try await ControlClient.shared.read() ? "on" : "off")
            case "--read-system-state":
                print(try SystemDisplayFilter().read() ? "on" : "off")
            case "--install-control":
                try await ControlInstallationPreparation.perform(openApplication: openApplicationForSetup) {
                    try ControlCenterIntegration.install()
                }
                print("installed")
            case "--install-schedule":
                try await ScheduleService.install(settings: SettingsStore.load())
                print("installed")
            case "--remove-control":
                try ControlCenterIntegration.remove()
                print("removed")
            case "--remove-schedule":
                try ScheduleService.remove()
                print("removed")
            case "--remove-legacy-control":
                try ControlCenterIntegration.removeLegacyAccessibilityShortcut()
                print("removed")
            case "--self-test":
                try SelfTest.run()
                print("self-test passed")
            default:
                throw NSError(
                    domain: AppConfiguration.bundleIdentifier,
                    code: 64,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown option: \(command)"]
                )
            }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    @MainActor
    private static func openApplicationForSetup() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        // The installing executable or helper may already be running. Setup
        // needs a normal app launch, not a reopen event delivered to that CLI.
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        )
    }
}

private enum SelfTest {
    static func run() throws {
        let overnight = ScheduleSettings.standard
        let cases = [
            (minute: 21 * 60 + 59, expected: false),
            (minute: 22 * 60, expected: true),
            (minute: 4 * 60 + 59, expected: true),
            (minute: 5 * 60, expected: false),
        ]
        guard cases.allSatisfy({ overnight.shouldEnable(atMinute: $0.minute) == $0.expected }),
              !ScheduleSettings(
                enabled: false, start: overnight.start, end: overnight.end
              ).shouldEnable(atMinute: 23 * 60),
              ControlIdentity.isValid,
              ControlURLCommand(url: AppConfiguration.filterURL(enabled: true)) == .set(true),
              ControlURLCommand(url: AppConfiguration.filterURL(enabled: false)) == .set(false)
        else {
            throw NSError(
                domain: AppConfiguration.bundleIdentifier,
                code: 70,
                userInfo: [NSLocalizedDescriptionKey: "An internal invariant failed."]
            )
        }
    }
}

if CommandLine.arguments.dropFirst().first == "--serve-control" {
    do { try ControlServiceHost.run() }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
if CommandLine.arguments.dropFirst().first?.hasPrefix("--") == true {
    Task { await CommandLineInterface.run(arguments: CommandLine.arguments.dropFirst()) }
    dispatchMain()
}

let application = NSApplication.shared
let delegate = AppDelegate()
let urlCommandHandler = URLCommandHandler(delegate: delegate)
application.delegate = delegate
NSAppleEventManager.shared().setEventHandler(
    urlCommandHandler,
    andSelector: #selector(URLCommandHandler.handleGetURLEvent(_:withReplyEvent:)),
    forEventClass: 0x4755524C,
    andEventID: 0x4755524C
)
application.setActivationPolicy(.accessory)
application.run()
