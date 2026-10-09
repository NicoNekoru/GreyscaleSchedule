import Darwin
import Foundation
import CryptoKit

enum LaunchAgentManager {
    typealias Executor = (String, [String]) -> ProcessRunner.Result
    private static var domain: String { "gui/\(getuid())" }
    static func isLoaded(label: String, run: Executor = ProcessRunner.execute) -> Bool {
        run("/bin/launchctl", ["print", "\(domain)/\(label)"]).status == 0
    }

    static func install(_ definition: [String: Any], at url: URL, label: String,
                        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                        run: Executor = ProcessRunner.execute) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
        let oldData = try existingData(at: url)
        let wasLoaded = isLoaded(label: label, run: run)
        if oldData == data && wasLoaded { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if wasLoaded { try checked(["bootout", "\(domain)/\(label)"], run: run) }
        do {
            try data.write(to: url, options: .atomic)
            try bootstrap(url, retryAfterBootout: wasLoaded, pause: pause, run: run)
        } catch {
            do {
                if let oldData {
                    try oldData.write(to: url, options: .atomic)
                    if wasLoaded { try checked(["bootstrap", domain, url.path], run: run) }
                } else if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch let rollbackError {
                throw NSError(domain: AppConfiguration.bundleIdentifier, code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Agent installation failed and its previous configuration could not be restored. \(rollbackError.localizedDescription)"])
            }
            throw error
        }
    }

    static func remove(at url: URL, label: String, run: Executor = ProcessRunner.execute) throws {
        if isLoaded(label: label, run: run) { try checked(["bootout", "\(domain)/\(label)"], run: run) }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private static func checked(_ arguments: [String], run: Executor) throws {
        try ProcessRunner.check(run("/bin/launchctl", arguments), executable: "/bin/launchctl")
    }

    private static func bootstrap(_ url: URL, retryAfterBootout: Bool,
                                  pause: (TimeInterval) -> Void, run: Executor) throws {
        // launchd can acknowledge bootout before releasing the old Mach endpoint.
        // Retry only its transient EIO response, only after our own bootout, and
        // with a bounded backoff. Other failures retain their diagnostics.
        let delays: [TimeInterval] = retryAfterBootout ? [0.05, 0.1, 0.2, 0.4] : []
        for attempt in 0...delays.count {
            let result = run("/bin/launchctl", ["bootstrap", domain, url.path])
            if result.status == 5 && attempt < delays.count { pause(delays[attempt]); continue }
            try ProcessRunner.check(result, executable: "/bin/launchctl")
            return
        }
    }

    private static func existingData(at url: URL) throws -> Data? {
        FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
}

enum ControlRequestAgent {
    static func definition(executable: String, fingerprint: String) -> [String: Any] {
        ["Label": AppConfiguration.controlAgentLabel,
         "ProgramArguments": [executable, "--serve-control"],
         "MachServices": [AppConfiguration.controlAgentLabel: true],
         // A same-path app upgrade must retire the old helper process too.
         "EnvironmentVariables": ["GREYSCALE_HELPER_BINARY_SHA256": fingerprint],
         "ProcessType": "Background",
         "StandardOutPath": AppPaths.log.path,
         "StandardErrorPath": AppPaths.log.path]
    }

    static func install() throws {
        guard let executable = Bundle.main.executableURL?.path else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: AppPaths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try LaunchAgentManager.install(definition(executable: executable, fingerprint: fingerprint), at: AppPaths.controlLaunchAgent,
                                       label: AppConfiguration.controlAgentLabel)
    }
    static func remove() throws {
        try LaunchAgentManager.remove(at: AppPaths.controlLaunchAgent, label: AppConfiguration.controlAgentLabel)
    }
}
