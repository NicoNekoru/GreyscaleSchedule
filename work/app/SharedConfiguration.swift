import Foundation

enum AppConfiguration {
    static let appName = "Greyscale Schedule"
    static let bundleIdentifier = "local.greyscale-schedule"
    static let extensionBundleIdentifier = "local.greyscale-schedule.control2"
    static let legacyExtensionBundleIdentifier = "local.greyscale-schedule.control"
    static let controlKind = "local.greyscale-schedule.control2.greyscale"
    static let urlScheme = "greyscale-schedule"
    static let launchAgentLabel = bundleIdentifier
    static let controlAgentLabel = "\(bundleIdentifier).control-agent"

    static let extensionBundleIdentifiers = [
        legacyExtensionBundleIdentifier,
        extensionBundleIdentifier,
    ]

    static func filterURL(enabled: Bool) -> URL {
        URL(string: "\(urlScheme)://set/\(enabled ? "on" : "off")")!
    }
}

enum AppPaths {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    static let launchAgent = home
        .appendingPathComponent("Library/LaunchAgents")
        .appendingPathComponent("\(AppConfiguration.launchAgentLabel).plist")
    static let controlLaunchAgent = home
        .appendingPathComponent("Library/LaunchAgents")
        .appendingPathComponent("\(AppConfiguration.controlAgentLabel).plist")
    static let log = home
        .appendingPathComponent("Library/Logs")
        .appendingPathComponent("\(AppConfiguration.appName).log")
    static let support = home
        .appendingPathComponent("Library/Application Support")
        .appendingPathComponent(AppConfiguration.appName)
    static let controlRequests = support.appendingPathComponent("Control Requests")
    static let controlResponses = support.appendingPathComponent("Control Responses")

    static func controlResponse(identifier: String) -> URL {
        controlResponses.appendingPathComponent("\(identifier).json")
    }

    static func extensionContainer(for bundleIdentifier: String) -> URL {
        home.appendingPathComponent("Library/Containers/\(bundleIdentifier)")
    }
}
