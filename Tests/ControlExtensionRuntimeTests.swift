import Foundation
import XCTest
@testable import GreyscaleCore

private final class FakeExtensionProcesses {
    let extensionURL = URL(fileURLWithPath: "/fake/Greyscale Schedule.app/Contents/PlugIns/GreyscaleControl.appex")
    var paths: [String: String] = [:]
    var stale: Set<String> = []
    var previousBuild: Set<String> = []
    var hashReadError = false
    var diskValid = true
    var discoveryError = false
    var malformedPID = false
    var reusePIDAfterVerification = false
    var terminationError = false
    var exitsOnTermination = true
    var verifiedProcesses: [String] = []
    var diskChecks = 0
    var terminated: [String] = []
    var pauses: [TimeInterval] = []
    var executable: String { extensionURL.appendingPathComponent("Contents/MacOS/GreyscaleControl").path }

    func add(_ pid: String, stale: Bool, path: String? = nil) {
        paths[pid] = path ?? executable
        if stale { self.stale.insert(pid) }
    }
    func run(_ command: String, _ arguments: [String]) -> ProcessRunner.Result {
        switch command {
        case "/usr/bin/pgrep":
            XCTAssertEqual(arguments, ["-x", "GreyscaleControl"])
            if discoveryError { return .init(status: 2, output: "discovery failed") }
            if malformedPID { return .init(status: 0, output: "invalid PID") }
            return .init(status: paths.isEmpty ? 1 : 0, output: paths.keys.sorted().joined(separator: "\n"))
        case "/bin/ps":
            XCTAssertEqual(arguments[0], "-p")
            XCTAssertEqual(arguments.suffix(2), ["-o", "comm="])
            guard let path = paths[arguments[1]] else { return .init(status: 1, output: "") }
            return .init(status: 0, output: "  \(path)\n")
        case "/usr/bin/codesign":
            let target = arguments.last!
            if arguments.first == "--display" {
                XCTAssertEqual(arguments, ["--display", "--verbose=3", target])
                if hashReadError { return .init(status: 0, output: "no readable hash") }
                return .init(status: 0, output: "CDHash=\(String(repeating: previousBuild.contains(target) ? "b" : "a", count: 40))\n")
            }
            if target == extensionURL.path {
                XCTAssertEqual(arguments, ["--verify", "--deep", "--strict", extensionURL.path])
                diskChecks += 1
                return .init(status: diskValid ? 0 : 1, output: diskValid ? "" : "replacement signature invalid")
            }
            XCTAssertEqual(arguments, ["--verify", "--strict", target])
            verifiedProcesses.append(target)
            if reusePIDAfterVerification { paths[target] = "/another/application" }
            return .init(status: stale.contains(target) ? 1 : 0, output: "")
        case "/bin/kill":
            XCTAssertEqual(arguments.first, "-TERM")
            if terminationError { return .init(status: 1, output: "termination denied") }
            terminated.append(arguments[1])
            if exitsOnTermination { paths.removeValue(forKey: arguments[1]) }
            return .init(status: 0, output: "")
        default:
            XCTFail("Unexpected process command \(command)")
            return .init(status: -1, output: "unexpected command")
        }
    }
    func recover() throws -> Bool {
        try ControlExtensionRuntime.retireStaleProcesses(extensionURL: extensionURL,
                                                         pause: { self.pauses.append($0) }, run: run)
    }
}

final class ControlExtensionRuntimeTests: XCTestCase {
    func testNoRunningExtensionDoesNotChangeAnything() throws {
        let system = FakeExtensionProcesses()
        XCTAssertFalse(try system.recover())
        XCTAssertTrue(system.terminated.isEmpty)
        XCTAssertEqual(system.diskChecks, 0)
    }
    func testHealthyInstalledExtensionIsNotRestarted() throws {
        let system = FakeExtensionProcesses(); system.add("123", stale: false)
        XCTAssertFalse(try system.recover())
        XCTAssertEqual(system.verifiedProcesses, ["123"])
        XCTAssertTrue(system.terminated.isEmpty)
        XCTAssertEqual(system.diskChecks, 0)
    }
    func testUpgradeRetiresOnlyStaleExtensionAtTheExactInstalledPath() throws {
        let system = FakeExtensionProcesses()
        system.add("123", stale: true)
        system.add("124", stale: false)
        system.add("125", stale: true, path: "/another/GreyscaleControl")
        system.add("126", stale: true, path: "/fake/Greyscale Schedule.app.backup/Contents/PlugIns/GreyscaleControl.appex/Contents/MacOS/GreyscaleControl")
        XCTAssertTrue(try system.recover())
        XCTAssertEqual(system.terminated, ["123"])
        XCTAssertEqual(system.verifiedProcesses, ["123", "124"])
        XCTAssertEqual(system.diskChecks, 1)
        XCTAssertFalse(try system.recover())
        XCTAssertEqual(system.terminated, ["123"])
    }
    func testInvalidReplacementFailsBeforeStoppingPreviousExtension() {
        let system = FakeExtensionProcesses(); system.add("123", stale: true); system.diskValid = false
        XCTAssertThrowsError(try system.recover()) { error in
            XCTAssertTrue(error.localizedDescription.contains("replacement signature invalid"))
        }
        XCTAssertTrue(system.terminated.isEmpty)
    }
    func testMovedBackupWithValidSignatureStillRetiresThePreviousBuild() throws {
        let system = FakeExtensionProcesses(); system.add("123", stale: false)
        system.previousBuild.insert("123")
        XCTAssertTrue(try system.recover())
        XCTAssertEqual(system.terminated, ["123"])
        XCTAssertEqual(system.diskChecks, 1)
    }
    func testUnreadableCodeHashFailsClosedInsteadOfStoppingAHealthyProcess() {
        let system = FakeExtensionProcesses(); system.add("123", stale: false); system.hashReadError = true
        XCTAssertThrowsError(try system.recover())
        XCTAssertTrue(system.terminated.isEmpty)
    }
    func testPIDReusedByAnotherProcessIsNotTerminated() throws {
        let system = FakeExtensionProcesses(); system.add("123", stale: true); system.reusePIDAfterVerification = true
        XCTAssertFalse(try system.recover())
        XCTAssertTrue(system.terminated.isEmpty)
    }
    func testTerminationFailureIsReportedInsteadOfClaimingRecovery() {
        let system = FakeExtensionProcesses(); system.add("123", stale: true); system.terminationError = true
        XCTAssertThrowsError(try system.recover()) { error in
            XCTAssertTrue(error.localizedDescription.contains("termination denied"))
        }
    }
    func testWaitForExitIsBoundedAndFailureIsReported() {
        let system = FakeExtensionProcesses(); system.add("123", stale: true); system.exitsOnTermination = false
        XCTAssertThrowsError(try system.recover()) { error in
            XCTAssertTrue(error.localizedDescription.contains("did not stop"))
        }
        XCTAssertEqual(system.terminated, ["123"])
        XCTAssertEqual(system.pauses, Array(repeating: 0.05, count: 20))
    }
    func testDiscoveryFailureDoesNotSignalAnyProcess() {
        let system = FakeExtensionProcesses(); system.discoveryError = true
        XCTAssertThrowsError(try system.recover())
        XCTAssertTrue(system.terminated.isEmpty)
    }
    func testMalformedProcessIdentifierFailsClosed() {
        let system = FakeExtensionProcesses(); system.malformedPID = true
        XCTAssertThrowsError(try system.recover())
        XCTAssertTrue(system.terminated.isEmpty)
    }
}
