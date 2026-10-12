import Darwin
import Foundation
import CryptoKit
import WidgetKit

/// A same-path upgrade can leave the old widget process alive. Its in-memory
/// signature then disagrees with the new Info.plist, so the signed XPC helper
/// rejects it and WidgetKit replaces the tile with an empty error placeholder.
/// Retire only stale processes at this app's exact extension path. Never relax
/// the helper's signing requirement or stop another app's widget.
enum ControlExtensionRuntime {
    typealias Executor = (String, [String]) -> ProcessRunner.Result

    @discardableResult
    static func retireStaleProcesses(extensionURL: URL,
                                    pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                    run: Executor = ProcessRunner.execute) throws -> Bool {
        let candidates = run("/usr/bin/pgrep", ["-x", "GreyscaleControl"])
        if candidates.status == 1 { return false }
        try ProcessRunner.check(candidates, executable: "/usr/bin/pgrep")
        let executable = extensionURL.appendingPathComponent("Contents/MacOS/GreyscaleControl").path
        var installedHash: String?
        var retired = false
        for line in candidates.output.split(whereSeparator: \.isWhitespace) {
            guard let pid = Int32(line), pid > 1 else {
                throw NSError(domain: AppConfiguration.bundleIdentifier, code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The running control extension could not be identified."])
            }
            let identifier = String(pid)
            func isOurProcess() -> Bool {
                let process = run("/bin/ps", ["-p", identifier, "-o", "comm="])
                return process.status == 0 && process.output.trimmingCharacters(in: .whitespacesAndNewlines) == executable
            }
            guard isOurProcess() else { continue }
            let signature = run("/usr/bin/codesign", ["--verify", "--strict", identifier])
            if signature.status == -1 { try ProcessRunner.check(signature, executable: "/usr/bin/codesign") }
            if signature.status == 0 {
                // Moving the old app aside can keep its signature valid even
                // though that process still runs the previous build. Compare
                // CodeDirectory hashes as well as checking validity.
                if installedHash == nil { installedHash = try codeHash(extensionURL.path, run: run) }
                guard isOurProcess() else { continue }
                if try codeHash(identifier, run: run) == installedHash { continue }
            }
            // A bad replacement must be fixed on disk, not retried by killing
            // the healthy previous process. Verify before sending any signal.
            try ProcessRunner.check(run("/usr/bin/codesign", ["--verify", "--deep", "--strict", extensionURL.path]),
                                    executable: "/usr/bin/codesign")
            guard isOurProcess() else { continue } // It may have exited or its PID may have been reused.
            let termination = run("/bin/kill", ["-TERM", identifier])
            if termination.status != 0 {
                if isOurProcess() { try ProcessRunner.check(termination, executable: "/bin/kill") }
                continue
            }
            // Let the previous process exit before asking WidgetKit to launch
            // the replacement, rather than immediately reusing the old one.
            for _ in 0..<20 {
                if !isOurProcess() { break }
                pause(0.05)
            }
            guard !isOurProcess() else {
                throw NSError(domain: AppConfiguration.bundleIdentifier, code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The previous control extension did not stop. Retry Refresh Control."])
            }
            retired = true
        }
        return retired
    }

    private static func codeHash(_ target: String, run: Executor) throws -> String {
        let signature = run("/usr/bin/codesign", ["--display", "--verbose=3", target])
        try ProcessRunner.check(signature, executable: "/usr/bin/codesign")
        guard let line = signature.output.split(separator: "\n").first(where: { $0.hasPrefix("CDHash=") }) else {
            throw hashReadError()
        }
        let hash = String(line.dropFirst("CDHash=".count))
        guard hash.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil else { throw hashReadError() }
        return hash.lowercased()
    }
    private static func hashReadError() -> Error {
        NSError(domain: AppConfiguration.bundleIdentifier, code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The control extension's code signature could not be compared. Retry Refresh Control."])
    }
}

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
        let fingerprint = try fingerprint(executable: executable)
        try LaunchAgentManager.install(definition(executable: executable, fingerprint: fingerprint), at: AppPaths.controlLaunchAgent,
                                       label: AppConfiguration.controlAgentLabel)
        try repairExtensionRuntime()
    }
    static func repairExtensionRuntime() throws {
        guard let plugins = Bundle.main.builtInPlugInsURL else { throw CocoaError(.fileNoSuchFile) }
        let url = plugins.appendingPathComponent("GreyscaleControl.appex")
        if try ControlExtensionRuntime.retireStaleProcesses(extensionURL: url) {
            ControlDiagnostics.record("Retired stale control extension after app update; refreshing control")
            ControlCenter.shared.reloadControls(ofKind: AppConfiguration.controlKind)
        }
    }
    static func remove() throws {
        try LaunchAgentManager.remove(at: AppPaths.controlLaunchAgent, label: AppConfiguration.controlAgentLabel)
    }
    static func fingerprint(executable: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: executable), options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
