import Foundation

enum ProcessRunner {
    struct Result {
        let status: Int32
        let output: String
    }

    static func execute(_ executable: String, _ arguments: [String]) -> Result {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(status: process.terminationStatus,
                          output: String(data: data, encoding: .utf8) ?? "")
        } catch { return Result(status: -1, output: error.localizedDescription) }
    }

    static func checked(_ executable: String, _ arguments: [String]) throws {
        try check(execute(executable, arguments), executable: executable)
    }

    static func check(_ result: Result, executable: String) throws {
        guard result.status == 0 else {
            throw NSError(domain: AppConfiguration.bundleIdentifier, code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey:
                            "\(URL(fileURLWithPath: executable).lastPathComponent) failed. \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        execute(executable, arguments).status
    }
}
