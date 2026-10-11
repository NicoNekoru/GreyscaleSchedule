import Foundation
import XCTest
@testable import GreyscaleCore

private enum FakeFailure: Error { case read, write }
private final class FakeFilter: DisplayFilterBackend {
    private let lock = NSLock()
    private var actual = false
    private var pending: Bool?
    private var remaining = 0
    var delayReads = 0
    var refusesWrite = false
    var failsRead = false
    var writeGate: DispatchSemaphore?
    var writeStarted: DispatchSemaphore?
    private var writesStorage: [Bool] = []
    private var eventsStorage: [String] = []
    var writes: [Bool] { lock.withLock { writesStorage } }
    var events: [String] { lock.withLock { eventsStorage } }
    func changeExternally(_ value: Bool) { lock.withLock { actual = value } }
    func read() throws -> Bool {
        try lock.withLock {
            if failsRead { throw FakeFailure.read }
            if let pending {
                if remaining == 0 { actual = pending; self.pending = nil }
                else { remaining -= 1 }
            }
            eventsStorage.append("read:\(actual)")
            return actual
        }
    }
    func write(_ value: Bool) throws {
        lock.withLock {
            writesStorage.append(value); eventsStorage.append("write:\(value)")
            if !refusesWrite { pending = value; remaining = delayReads }
        }
        writeStarted?.signal()
        if let writeGate, writeGate.wait(timeout: .now() + 5) != .success { throw FakeFailure.write }
    }
    func reloaded(_ value: Bool) { lock.withLock { eventsStorage.append("reload:\(value)") } }
}

private final class FakeClock {
    var value: TimeInterval = 100
    func advance(_ duration: TimeInterval) { value += duration }
}

private func controller(_ backend: FakeFilter, clock: FakeClock = FakeClock()) -> DisplayStateController {
    DisplayStateController(backend: backend, confirmationTimeout: 0.5,
        now: { clock.value }, pause: { clock.advance($0) }, changed: { backend.reloaded($0) })
}
private func read(_ controller: DisplayStateController) async throws -> Bool {
    try await withCheckedThrowingContinuation { continuation in controller.read { continuation.resume(with: $0) } }
}
private func set(_ controller: DisplayStateController, _ value: Bool,
                 deadline: TimeInterval = 200, operation: DisplayOperation = DisplayOperation()) async throws -> Bool {
    try await withCheckedThrowingContinuation { continuation in
        controller.set(value, deadline: deadline, operation: operation) { continuation.resume(with: $0) }
    }
}

final class DisplayStateTests: XCTestCase {
    func testRestartedHelperPublishesInitialTruthEvenForAnUnchangedSchedule() async throws {
        for enabled in [false, true] {
            let filter = FakeFilter(); filter.changeExternally(enabled)
            let actual = try await set(controller(filter), enabled)
            XCTAssertEqual(actual, enabled)
            XCTAssertEqual(filter.writes, [])
            XCTAssertEqual(filter.events.filter { $0.hasPrefix("reload") }, ["reload:\(enabled)"])
        }
    }
    func testReloadOnlyAfterActualConfirmation() async throws {
        let filter = FakeFilter(); filter.delayReads = 3
        let state = controller(filter)
        let actual = try await set(state, true)
        XCTAssertTrue(actual)
        XCTAssertEqual(filter.events, ["read:false", "reload:false", "write:true", "read:false", "read:false",
                                        "read:false", "read:true", "reload:true"])
        let same = try await set(state, true)
        XCTAssertTrue(same)
        XCTAssertEqual(filter.writes, [true])
        XCTAssertEqual(filter.events.filter { $0.hasPrefix("reload") }, ["reload:false", "reload:true"])
    }
    func testFreshReadsTrackSystemSettingsChanges() async throws {
        let filter = FakeFilter(); let state = controller(filter)
        let before = try await read(state); XCTAssertFalse(before)
        filter.changeExternally(true)
        let after = try await read(state); XCTAssertTrue(after)
        _ = try await read(state)
        filter.changeExternally(false)
        _ = try await read(state)
        XCTAssertEqual(filter.events.filter { $0.hasPrefix("reload") }, ["reload:false", "reload:true", "reload:false"])
    }
    func testFailedWriteDoesNotPublishRequestedValue() async throws {
        let filter = FakeFilter(); filter.refusesWrite = true
        let state = controller(filter)
        do { _ = try await set(state, true); XCTFail("Unconfirmed write succeeded") }
        catch { XCTAssertTrue(error is DisplayStateError) }
        let actual = try await read(state); XCTAssertFalse(actual)
        XCTAssertFalse(filter.events.contains("reload:true"))
    }
    func testReadFailureIsNotReportedAsOff() async {
        let filter = FakeFilter(); filter.failsRead = true
        do { _ = try await read(controller(filter)); XCTFail("Read error was hidden") }
        catch { XCTAssertTrue(error is FakeFailure) }
    }
    func testTwelveOverlappingCommandsAreSerializedAndConfirmed() async throws {
        let filter = FakeFilter(); filter.delayReads = 2
        let state = controller(filter)
        let finished = expectation(description: "all commands acknowledged"); finished.expectedFulfillmentCount = 12
        for i in 0..<12 {
            let desired = i.isMultiple(of: 2)
            state.set(desired, deadline: 200, operation: DisplayOperation()) { result in
                switch result {
                case .success(let actual): XCTAssertEqual(actual, desired)
                case .failure(let error): XCTFail("\(error)")
                }
                finished.fulfill()
            }
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(filter.writes, (0..<12).map { $0.isMultiple(of: 2) })
        let actual = try await read(state); XCTAssertFalse(actual)
        XCTAssertEqual(filter.events.filter { $0.hasPrefix("reload") }.count, 13)
    }
    func testCancelledQueuedCommandNeverWrites() async throws {
        let filter = FakeFilter(); let clock = FakeClock(); let state = controller(filter, clock: clock)
        let cancelled = DisplayOperation(); cancelled.cancel()
        do { _ = try await set(state, true, operation: cancelled); XCTFail("Cancelled command succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(filter.writes, [])
        XCTAssertFalse(cancelled.hasCommitted)
    }
    func testExpiredQueuedCommandNeverWrites() async {
        let filter = FakeFilter()
        do { _ = try await set(controller(filter), true, deadline: 99); XCTFail("Expired command succeeded") }
        catch { XCTAssertTrue(error is DisplayStateError) }
        XCTAssertEqual(filter.writes, [])
    }
    func testCancellationAfterCommitDoesNotUndoNewerState() async throws {
        let filter = FakeFilter(); filter.writeGate = DispatchSemaphore(value: 0)
        filter.writeStarted = DispatchSemaphore(value: 0)
        let state = controller(filter); let operation = DisplayOperation()
        let first = Task { try await set(state, true, operation: operation) }
        XCTAssertEqual(filter.writeStarted?.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(operation.hasCommitted)
        operation.cancel(); filter.writeGate?.signal()
        let actual = try await first.value; XCTAssertTrue(actual)
        filter.writeGate = nil
        let next = try await set(state, false); XCTAssertFalse(next)
        XCTAssertEqual(filter.writes, [true, false])
    }
}

private final class FakeControlReloads {
    private let lock = NSLock()
    private var countStorage = 0
    private var retries: [() -> Void] = []
    var count: Int { lock.withLock { countStorage } }
    var queuedRetries: Int { lock.withLock { retries.count } }
    func reload() { lock.withLock { countStorage += 1 } }
    func schedule(_ retry: @escaping () -> Void) { lock.withLock { retries.append(retry) } }
    func runNextRetry() {
        let retry = lock.withLock { retries.isEmpty ? nil : retries.removeFirst() }
        retry?()
    }
    func coordinator() -> ControlRefreshCoordinator {
        ControlRefreshCoordinator(reload: reload, scheduleRetry: schedule)
    }
}

final class ControlRefreshTests: XCTestCase {
    func testHiddenControlReloadRetriesUntilProviderSamplesIt() {
        let reloads = FakeControlReloads(); let refresh = reloads.coordinator()
        refresh.request(true)
        XCTAssertEqual(reloads.count, 1)
        for _ in 0..<4 { reloads.runNextRetry() }
        XCTAssertEqual(reloads.count, 5)
        XCTAssertEqual(reloads.queuedRetries, 1)
        XCTAssertTrue(refresh.sampled(true))
        reloads.runNextRetry()
        XCTAssertEqual(reloads.count, 5)
        XCTAssertEqual(reloads.queuedRetries, 0)
    }
    func testOldSampleCannotAcknowledgeANewerState() {
        let reloads = FakeControlReloads(); let refresh = reloads.coordinator()
        refresh.request(true)
        refresh.request(false)
        XCTAssertFalse(refresh.sampled(true))
        XCTAssertEqual(reloads.queuedRetries, 1)
        reloads.runNextRetry()
        XCTAssertEqual(reloads.count, 3)
        XCTAssertTrue(refresh.sampled(false))
        reloads.runNextRetry()
        XCTAssertEqual(reloads.queuedRetries, 0)
    }
    func testChangesCoalesceIntoOneRetryChainAndCanRestartAfterIdle() {
        let reloads = FakeControlReloads(); let refresh = reloads.coordinator()
        refresh.request(true)
        XCTAssertTrue(refresh.sampled(true))
        // Another boundary arrives before the already queued retry runs.
        refresh.request(false)
        XCTAssertEqual(reloads.queuedRetries, 1)
        reloads.runNextRetry()
        XCTAssertEqual(reloads.count, 3)
        XCTAssertTrue(refresh.sampled(false))
        reloads.runNextRetry()
        XCTAssertEqual(reloads.queuedRetries, 0)
        refresh.request(true)
        XCTAssertEqual(reloads.queuedRetries, 1)
        XCTAssertEqual(reloads.count, 4)
    }
    func testNoRefreshWorkWithoutAConfirmedState() {
        let reloads = FakeControlReloads(); let refresh = reloads.coordinator()
        XCTAssertFalse(refresh.sampled(false))
        reloads.runNextRetry()
        XCTAssertEqual(reloads.count, 0)
        XCTAssertEqual(reloads.queuedRetries, 0)
    }
    func testNoRetryLoopWhenControlIsNotInstalledOrHasBeenRemoved() {
        let reloads = FakeControlReloads()
        var installed = true
        let refresh = ControlRefreshCoordinator(reload: reloads.reload,
            shouldRetry: { installed }, scheduleRetry: reloads.schedule)
        refresh.request(true)
        reloads.runNextRetry()
        XCTAssertEqual(reloads.count, 2)
        installed = false
        reloads.runNextRetry()
        XCTAssertEqual(reloads.count, 2)
        XCTAssertEqual(reloads.queuedRetries, 0)
        XCTAssertFalse(refresh.sampled(true))
    }
    func testAppReadsCannotAcknowledgeTileReloadButProviderReadsCan() async throws {
        let filter = FakeFilter(); let reloads = FakeControlReloads()
        let refresh = reloads.coordinator()
        let state = DisplayStateController(backend: filter, changed: refresh.request)
        let listener = NSXPCListener.anonymous()
        let host = ControlServiceHost(controller: state, listener: listener,
                                      requireSignedPeer: false, refresh: refresh)
        try host.start()
        defer { listener.invalidate() }
        let client = ControlClient(timeout: 3) { NSXPCConnection(listenerEndpoint: listener.endpoint) }
        let actual = try await client.set(true); XCTAssertTrue(actual)
        let appState = try await client.read(); XCTAssertTrue(appState)
        reloads.runNextRetry()
        XCTAssertEqual(reloads.count, 3) // Initial truth, write confirmation, retry.
        let tileState = try await client.readForControl(); XCTAssertTrue(tileState)
        reloads.runNextRetry()
        XCTAssertEqual(reloads.count, 3)
        XCTAssertEqual(reloads.queuedRetries, 0)
        withExtendedLifetime(host) {}
    }
    func testFailedProviderReadKeepsRefreshPending() async throws {
        let filter = FakeFilter(); let reloads = FakeControlReloads()
        let refresh = reloads.coordinator()
        let state = DisplayStateController(backend: filter, changed: refresh.request)
        let session = ControlServiceSession(controller: state, refresh: refresh)
        _ = try await read(state)
        filter.failsRead = true
        let done = expectation(description: "failed provider read")
        session.readForControl { _, error in XCTAssertNotNil(error); done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
        reloads.runNextRetry()
        XCTAssertEqual(reloads.count, 2)
        XCTAssertEqual(reloads.queuedRetries, 1)
    }
    func testBothScheduleBoundariesRefreshWithoutAnAppWindow() async throws {
        let filter = FakeFilter(); let reloads = FakeControlReloads()
        let refresh = reloads.coordinator()
        let state = DisplayStateController(backend: filter, changed: refresh.request)
        let listener = NSXPCListener.anonymous()
        let host = ControlServiceHost(controller: state, listener: listener,
                                      requireSignedPeer: false, refresh: refresh)
        try host.start()
        defer { listener.invalidate() }
        let client = ControlClient(timeout: 3) { NSXPCConnection(listenerEndpoint: listener.endpoint) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for (date, expected) in [("2026-10-10T22:00:00Z", true), ("2026-10-11T05:00:00Z", false)] {
            try await ScheduleService.apply(.standard, on: ISO8601DateFormatter().date(from: date)!, calendar: calendar) {
                _ = try await client.set($0)
            }
            let countBeforeRetry = reloads.count
            reloads.runNextRetry()
            XCTAssertEqual(reloads.count, countBeforeRetry + 1)
            let actual = try await client.readForControl(); XCTAssertEqual(actual, expected)
            reloads.runNextRetry()
            XCTAssertEqual(reloads.count, countBeforeRetry + 1)
            XCTAssertEqual(reloads.queuedRetries, 0)
        }
        XCTAssertEqual(filter.writes, [true, false])
        withExtendedLifetime(host) {}
    }
}

final class ControlTransportTests: XCTestCase {
    func testTimeoutOfConnectedButUnresponsiveService() async throws {
        let listener = NSXPCListener.anonymous()
        let stalled = StalledService()
        listener.delegate = stalled; listener.resume()
        defer { listener.invalidate() }
        let client = ControlClient(timeout: 0.05) { NSXPCConnection(listenerEndpoint: listener.endpoint) }
        do { _ = try await client.read(); XCTFail("Stalled service succeeded") }
        catch ControlRequestError.timedOut {}
        catch { XCTFail("Expected timeout, got \(error)") }
        withExtendedLifetime(stalled) {}
    }
    func testCancellationOfConnectedClientCompletesPromptly() async throws {
        let listener = NSXPCListener.anonymous()
        let stalled = StalledService(); let received = expectation(description: "received request")
        stalled.received = { received.fulfill() }
        listener.delegate = stalled; listener.resume()
        defer { listener.invalidate() }
        let client = ControlClient(timeout: 3) { NSXPCConnection(listenerEndpoint: listener.endpoint) }
        let task = Task { try await client.set(true) }
        await fulfillment(of: [received], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        withExtendedLifetime(stalled) {}
    }
    func testCancelMessageBeforeSetIsRemembered() async {
        let filter = FakeFilter()
        let session = ControlServiceSession(controller: controller(filter))
        session.cancel("cancelled-before-delivery")
        let done = expectation(description: "cancelled command")
        session.set(true, identifier: "cancelled-before-delivery", deadline: ProcessInfo.processInfo.systemUptime + 3) { _, error in
            XCTAssertNotNil(error); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(filter.writes, [])
    }
    func testInvalidRemoteDeadlineCannotWrite() async {
        let filter = FakeFilter()
        let state = DisplayStateController(backend: filter, changed: { _ in })
        let session = ControlServiceSession(controller: state)
        let done = expectation(description: "invalid deadline")
        session.set(true, identifier: "invalid", deadline: .infinity) { _, error in
            XCTAssertNotNil(error); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(filter.writes, [])
    }
    func testWidgetAndAppClientsUseSameFreshServiceState() async throws {
        let filter = FakeFilter()
        let listener = NSXPCListener.anonymous()
        let host = ControlServiceHost(controller: controller(filter), listener: listener, requireSignedPeer: false)
        try host.start()
        defer { listener.invalidate() }
        let app = ControlClient(timeout: 3) { NSXPCConnection(listenerEndpoint: listener.endpoint) }
        let widget = ControlClient(timeout: 3) { NSXPCConnection(listenerEndpoint: listener.endpoint) }
        let on = try await app.set(true); XCTAssertTrue(on)
        let tile = try await widget.read(); XCTAssertTrue(tile)
        filter.changeExternally(false)
        let changed = try await widget.read(); XCTAssertFalse(changed)
        withExtendedLifetime(host) {}
    }
    func testInvalidatedConnectionCancelsQueuedWrite() async throws {
        let filter = FakeFilter(); filter.writeGate = DispatchSemaphore(value: 0)
        filter.writeStarted = DispatchSemaphore(value: 0)
        let state = controller(filter)
        let session = ControlServiceSession(controller: state)
        let done = expectation(description: "first write")
        session.set(true, identifier: "first", deadline: ProcessInfo.processInfo.systemUptime + 3) { _, _ in done.fulfill() }
        XCTAssertEqual(filter.writeStarted?.wait(timeout: .now() + 2), .success)
        let cancelled = expectation(description: "cancelled second")
        session.set(false, identifier: "second", deadline: ProcessInfo.processInfo.systemUptime + 3) { _, error in
            XCTAssertNotNil(error); cancelled.fulfill()
        }
        session.invalidate(); filter.writeGate?.signal()
        await fulfillment(of: [done, cancelled], timeout: 3)
        XCTAssertEqual(filter.writes, [true])
    }
    func testReplyGateHandlesCancellationBeforeContinuationAndLateReply() async {
        let gate = PendingControlReply()
        gate.finish(.failure(CancellationError()))
        do {
            let _: Bool = try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(gate.start(continuation))
                gate.finish(.success(true))
                gate.finish(.failure(ControlRequestError.timedOut))
            }
            XCTFail("Cancellation was lost")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testUnavailableServiceReportsError() async {
        let client = ControlClient(timeout: 0.2) { NSXPCConnection(machServiceName: "local.greyscale-schedule.test.missing") }
        do { _ = try await client.read(); XCTFail("Missing service reported off") }
        catch { XCTAssertTrue(error is ControlRequestError) }
    }
    func testPreCancelledClientDoesNotCreateAConnection() async {
        let client = ControlClient { XCTFail("Cancelled request connected"); return NSXPCConnection() }
        let ready = DispatchSemaphore(value: 0)
        func waitUntilReady() { ready.wait() }
        let task = Task {
            waitUntilReady()
            return try await client.set(true)
        }
        task.cancel(); ready.signal()
        do { _ = try await task.value; XCTFail("Cancelled task succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class StalledService: NSObject, GreyscaleControlServiceProtocol, NSXPCListenerDelegate {
    var received: (() -> Void)?
    private var replies: [(Bool, String?) -> Void] = []
    func read(reply: @escaping (Bool, String?) -> Void) { replies.append(reply); received?() }
    func readForControl(reply: @escaping (Bool, String?) -> Void) { replies.append(reply); received?() }
    func set(_ enabled: Bool, identifier: String, deadline: Double, reply: @escaping (Bool, String?) -> Void) { replies.append(reply); received?() }
    func cancel(_ identifier: String) {}
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: GreyscaleControlServiceProtocol.self)
        connection.exportedObject = self; connection.resume()
        return true
    }
}

final class HeadlessLifecycleTests: XCTestCase {
    func testFirstOfTwoFinishesCannotTerminateApp() {
        let tracker = ControlExecutionTracker()
        let first = tracker.begin(); let second = tracker.begin()
        XCTAssertFalse(tracker.finish(first)); XCTAssertNil(tracker.idleGeneration)
        XCTAssertEqual(tracker.activeCount, 1)
        XCTAssertTrue(tracker.finish(second)); XCTAssertNotNil(tracker.idleGeneration)
        XCTAssertFalse(tracker.finish(second))
    }
    func testDelayedTerminationIsInvalidatedByNewClick() {
        let tracker = ControlExecutionTracker(); let first = tracker.begin()
        XCTAssertTrue(tracker.finish(first))
        let old = tracker.idleGeneration!
        let second = tracker.begin(); XCTAssertTrue(tracker.finish(second))
        XCTAssertFalse(tracker.isStillIdle(generation: old))
        XCTAssertTrue(tracker.isStillIdle(generation: tracker.idleGeneration!))
    }
    func testControlNeverPresentsWindowButExplicitOpenStillWorks() {
        let tracker = ControlExecutionTracker()
        XCTAssertTrue(tracker.shouldPresentWindow(explicit: false, defaultLaunch: true))
        let ticket = tracker.begin()
        XCTAssertFalse(tracker.shouldPresentWindow(explicit: false, defaultLaunch: true))
        _ = tracker.finish(ticket)
        XCTAssertFalse(tracker.shouldPresentWindow(explicit: false, defaultLaunch: true))
        XCTAssertTrue(tracker.shouldPresentWindow(explicit: true, defaultLaunch: false))
    }
    func testFirstNormalOpenDoesNotDependOnAppActivation() {
        let tracker = ControlExecutionTracker()
        XCTAssertTrue(tracker.shouldPresentWindow(explicit: false, defaultLaunch: true))
    }
    func testNonDefaultLaunchDoesNotPresentSettingsBeforeIntentBegins() {
        let tracker = ControlExecutionTracker()
        XCTAssertFalse(tracker.shouldPresentWindow(explicit: false, defaultLaunch: false))
        XCTAssertTrue(tracker.shouldPresentWindow(explicit: true, defaultLaunch: false))
    }
}

final class ScheduleTests: XCTestCase {
    func testOvernightBoundaries() {
        let settings = ScheduleSettings.standard
        XCTAssertFalse(settings.shouldEnable(atMinute: 1319)); XCTAssertTrue(settings.shouldEnable(atMinute: 1320))
        XCTAssertTrue(settings.shouldEnable(atMinute: 299)); XCTAssertFalse(settings.shouldEnable(atMinute: 300))
    }
    func testDaytimeAndAllDay() {
        let day = ScheduleSettings(enabled: true, start: TimeOfDay(hour: 9, minute: 0), end: TimeOfDay(hour: 17, minute: 0))
        XCTAssertFalse(day.shouldEnable(atMinute: 539)); XCTAssertTrue(day.shouldEnable(atMinute: 540))
        XCTAssertTrue(day.shouldEnable(atMinute: 1019)); XCTAssertFalse(day.shouldEnable(atMinute: 1020))
        let all = ScheduleSettings(enabled: true, start: day.start, end: day.start)
        XCTAssertTrue(all.shouldEnable(atMinute: 0)); XCTAssertTrue(all.shouldEnable(atMinute: 1439))
    }
    func testDisabledAutomationDoesNotScheduleOrWriteOff() async throws {
        var settings = ScheduleSettings.standard; settings.enabled = false
        XCTAssertNil(ScheduleService.definition(settings: settings, executable: "/fake/app"))
        XCTAssertNil(settings.desiredState())
        try await ScheduleService.apply(settings) { _ in XCTFail("Disabled automation changed a manual choice") }
    }
    func testTimerUsesMacLocalTime() async throws {
        let utcDate = ISO8601DateFormatter().date(from: "2026-10-10T05:00:00Z")!
        var pacific = Calendar(identifier: .gregorian); pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var utc = pacific; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(ScheduleSettings.standard.desiredState(on: utcDate, calendar: pacific), true)
        XCTAssertEqual(ScheduleSettings.standard.desiredState(on: utcDate, calendar: utc), false)
    }
    func testAtomicSettingsRecordAndLegacyMigration() {
        let suite = "local.greyscale.tests.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "scheduleEnabled"); defaults.set(20, forKey: "startHour")
        let migrated = SettingsStore.load(from: defaults)
        XCTAssertFalse(migrated.enabled); XCTAssertEqual(migrated.start.hour, 20)
        var saved = migrated; saved.enabled = true; saved.end = TimeOfDay(hour: 7, minute: 15)
        SettingsStore.save(saved, to: defaults)
        defaults.set(false, forKey: "scheduleEnabled"); defaults.set(1, forKey: "endHour")
        XCTAssertEqual(SettingsStore.load(from: defaults), saved)
        XCTAssertNotNil(defaults.data(forKey: "schedule.v2"))
    }
    func testHelperIsOnDemandXPCNotFileQueue() {
        let definition = ControlRequestAgent.definition(executable: "/fake/app", fingerprint: "test-build")
        XCTAssertEqual(definition["ProgramArguments"] as? [String], ["/fake/app", "--serve-control"])
        XCTAssertNotNil(definition["MachServices"]); XCTAssertNil(definition["QueueDirectories"])
        XCTAssertEqual((definition["EnvironmentVariables"] as? [String: String])?["GREYSCALE_HELPER_BINARY_SHA256"], "test-build")
    }
}

final class FirstLaunchInstallationTests: XCTestCase {
    private func withDefaults(_ test: (UserDefaults) async throws -> Void) async rethrows {
        let suite = "local.greyscale.setup-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await test(defaults)
    }
    func testFirstInstallAwaitsAppOpeningAndRefreshDoesNotOpenAgain() async throws {
        try await withDefaults { defaults in
            var events: [String] = []
            let open = {
                events.append("opening")
                await Task.yield()
                events.append("opened")
            }
            let install = { events.append("installed") }
            try await ControlInstallationPreparation.perform(defaults: defaults,
                openApplication: open, installControl: install)
            try await ControlInstallationPreparation.perform(defaults: defaults,
                openApplication: open, installControl: install)
            XCTAssertEqual(events, ["opening", "opened", "installed", "installed"])
        }
    }
    func testExplicitAppOpeningSkipsInstallationLaunch() async throws {
        try await withDefaults { defaults in
            ControlInstallationPreparation.markAppOpened(in: defaults)
            var installed = false
            try await ControlInstallationPreparation.perform(defaults: defaults,
                openApplication: { XCTFail("Already opened app launched again") },
                installControl: { installed = true })
            XCTAssertTrue(installed)
        }
    }
    func testFailedFirstLaunchDoesNotInstallAndCanBeRetried() async throws {
        try await withDefaults { defaults in
            do {
                try await ControlInstallationPreparation.perform(defaults: defaults,
                    openApplication: { throw FakeFailure.write },
                    installControl: { XCTFail("Tile installed before app launch succeeded") })
                XCTFail("Launch failure was ignored")
            } catch { XCTAssertTrue(error is FakeFailure) }
            var opened = false
            try await ControlInstallationPreparation.perform(defaults: defaults,
                openApplication: { opened = true }, installControl: {})
            XCTAssertTrue(opened)
        }
    }
    func testFailedInstallationKeepsSuccessfulLaunchAndDoesNotReopenOnRetry() async throws {
        try await withDefaults { defaults in
            var opens = 0
            do {
                try await ControlInstallationPreparation.perform(defaults: defaults,
                    openApplication: { opens += 1 }, installControl: { throw FakeFailure.write })
                XCTFail("Installation failure was ignored")
            } catch { XCTAssertTrue(error is FakeFailure) }
            try await ControlInstallationPreparation.perform(defaults: defaults,
                openApplication: { opens += 1 }, installControl: {})
            XCTAssertEqual(opens, 1)
        }
    }
}

final class AgentInstallationTests: XCTestCase {
    private func temporaryAgent(_ test: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("greyscale-agent-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory.appendingPathComponent("agent.plist"))
    }
    func testLoadedIdenticalDefinitionDoesNotRestartHelper() throws {
        try temporaryAgent { url in
            let definition: [String: Any] = ["Label": "test.agent", "ProgramArguments": ["/fake/app"]]
            let data = try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
            try data.write(to: url)
            var commands: [String] = []
            try LaunchAgentManager.install(definition, at: url, label: "test.agent", run: { _, args in
                commands.append(args[0]); return .init(status: 0, output: "")
            })
            XCTAssertEqual(commands, ["print"]); XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }
    func testFailedUpgradeRestoresPreviousAgentAndReportsStderr() throws {
        try temporaryAgent { url in
            let old = Data("previous exact agent bytes".utf8); try old.write(to: url)
            var bootstrapCount = 0
            XCTAssertThrowsError(try LaunchAgentManager.install(["Label": "new"], at: url, label: "test.agent", pause: { _ in }) { _, args in
                if args[0] == "bootstrap" {
                    bootstrapCount += 1
                    if bootstrapCount <= 5 { return .init(status: 5, output: "intentional bootstrap failure") }
                }
                return .init(status: 0, output: "")
            }) { error in XCTAssertTrue(error.localizedDescription.contains("intentional bootstrap failure")) }
            XCTAssertEqual(bootstrapCount, 6); XCTAssertEqual(try Data(contentsOf: url), old)
        }
    }
    func testFailedBootoutDoesNotDeleteAgentOrClaimSuccessfulRemoval() throws {
        try temporaryAgent { url in
            let data = Data("keep this agent".utf8); try data.write(to: url)
            XCTAssertThrowsError(try LaunchAgentManager.remove(at: url, label: "test.agent") { _, args in
                .init(status: args[0] == "bootout" ? 5 : 0, output: "could not stop helper")
            }) { error in XCTAssertTrue(error.localizedDescription.contains("could not stop helper")) }
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }
    func testSamePathUpgradeChangesHelperDefinition() {
        let first = ControlRequestAgent.definition(executable: "/fake/app", fingerprint: "old-binary")
        let second = ControlRequestAgent.definition(executable: "/fake/app", fingerprint: "new-binary")
        XCTAssertNotEqual(first["EnvironmentVariables"] as? [String: String], second["EnvironmentVariables"] as? [String: String])
    }
    func testTransientMachEndpointReleaseIsRetriedWithoutRollingBack() throws {
        try temporaryAgent { url in
            let old = Data("old definition".utf8); try old.write(to: url)
            var bootstrapCount = 0; var pauses: [TimeInterval] = []
            try LaunchAgentManager.install(["Label": "updated"], at: url, label: "test.agent",
                                          pause: { pauses.append($0) }) { _, args in
                if args[0] == "bootstrap" {
                    bootstrapCount += 1
                    if bootstrapCount == 1 { return .init(status: 5, output: "old endpoint still draining") }
                }
                return .init(status: 0, output: "")
            }
            XCTAssertEqual(bootstrapCount, 2); XCTAssertEqual(pauses, [0.05])
            XCTAssertNotEqual(try Data(contentsOf: url), old)
        }
    }
}

private final class FakePreferences: ControlCenterPreferenceStore {
    var controls: Data?
    var layout: Data
    var failNextLayoutWrite = false
    var failNextControlsWrite = false
    var writes = 0
    var controlsReadCount = 0
    var mutateOnSecondRead = false
    init(controls: Data?, layout: Data) { self.controls = controls; self.layout = layout }
    func readControls() throws -> Data? {
        controlsReadCount += 1
        if mutateOnSecondRead && controlsReadCount == 2 { controls = Data("{\"Controls\":[],\"userEdited\":true}".utf8) }
        return controls
    }
    func readLayout() throws -> Data { layout }
    func writeControls(_ data: Data?) throws {
        writes += 1
        if failNextControlsWrite { failNextControlsWrite = false; throw FakeFailure.write }
        controls = data
    }
    func writeLayout(_ data: Data) throws {
        writes += 1
        if failNextLayoutWrite { failNextLayoutWrite = false; throw FakeFailure.write }
        layout = data
    }
}
private func fixtureLayout(identifier: String? = nil, size: String = "square1x1", secondPage: Bool = false) throws -> Data {
    let origin: [String: Any] = ["x": 2, "y": 1]
    let controls = identifier.map { [["rawValue": $0]] } ?? []
    let controlData = try PropertyListSerialization.data(fromPropertyList: controls, format: .binary, options: 0)
    let wrapper: [String: Any] = ["chronoControls": controlData, "instanceIds": controls, "unknownWrapper": "keep"]
    let data = try PropertyListSerialization.data(fromPropertyList: wrapper, format: .binary, options: 0)
    let elements: [[String: Any]] = identifier.map { [["id": ["rawValue": $0], "size": [size: [:]], "location": origin]] } ?? []
    let all = (0..<3).flatMap { y in (0..<4).map { ["x": $0, "y": y] } }
    let occupied = identifier == nil ? [] : [origin]
    let grid: [String: Any] = ["elements": elements, "width": 4, "maxHeight": 3, "allLocations": all,
                              "occupiedLocations": occupied, "unoccupiedLocations": all, "unknownGrid": 99]
    let page: [String: Any] = ["displayablesData": data.base64EncodedString(), "grid": grid, "unknownBox": "preserve"]
    return try JSONSerialization.data(withJSONObject: secondPage ? [page, page] : [page], options: [.sortedKeys])
}
private func fixtureRegistry(identifier: String? = nil, lookalike: Bool = false) throws -> Data {
    var controls: [[String: Any]] = []
    if let identifier {
        controls.append(["Identifier": [identifier], "ControlIdentity": ControlIdentity.encoded,
                         "ControlSize": 2, "DisplayName": "My customized tile", "unknownControl": "keep"])
    }
    if lookalike { controls.append(["Identifier": ["someone-elses-tile"], "DisplayName": "Greyscale",
                                    "ControlDescription": "greyscale", "ControlIdentity": "not-our-archive"] ) }
    return try JSONSerialization.data(withJSONObject: ["Controls": controls, "unknownRoot": "keep"], options: [.sortedKeys])
}

final class ControlInstallationTests: XCTestCase {
    private let previousContainer = "local.previous-app"
    private let previousExtension = "local.previous-app.control"
    private let previousKind = "local.previous-app.control.filter"
    private func previousIdentityRegistry(customName: Bool = false) throws -> Data {
        var archive = try PropertyListSerialization.propertyList(
            from: Data(base64Encoded: ControlIdentity.encoded)!, options: [], format: nil) as! [String: Any]
        archive["$objects"] = (archive["$objects"] as! [Any]).map { object -> Any in
            guard let string = object as? String else { return object }
            return string.replacingOccurrences(of: AppConfiguration.controlKind, with: previousKind)
                .replacingOccurrences(of: AppConfiguration.extensionBundleIdentifier, with: previousExtension)
                .replacingOccurrences(of: AppConfiguration.bundleIdentifier, with: previousContainer)
        }
        let encoded = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
            .base64EncodedString()
        var root = try JSONSerialization.jsonObject(with: fixtureRegistry(identifier: "existing", lookalike: true)) as! [String: Any]
        var controls = root["Controls"] as! [[String: Any]]
        controls[0]["ControlIdentity"] = encoded
        controls[0]["DisplayName"] = customName ? "My customized tile" : "Previous"
        controls[0]["ControlDescription"] = "Turn the previous display filter on or off."
        root["Controls"] = controls
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
    private func migratePrevious(_ store: FakePreferences, kind: String? = nil) throws {
        try ControlCenterTransaction.migrateIdentity(store: store, containerIdentifier: previousContainer,
            extensionIdentifier: previousExtension, kind: kind ?? previousKind, previousDisplayName: "Previous")
    }
    func testIdentifierMigrationPreservesTilePlacementSizeAndUnrelatedControls() throws {
        let store = FakePreferences(controls: try previousIdentityRegistry(),
            layout: try fixtureLayout(identifier: "existing", size: "rect2x1", secondPage: true))
        let originalLayout = store.layout
        let before = try JSONSerialization.jsonObject(with: store.controls!) as! [String: Any]
        try migratePrevious(store)
        XCTAssertEqual(store.layout, originalLayout)
        XCTAssertEqual(try CustomControlRegistry(data: store.controls).managedIdentifiers, ["existing"])
        let after = try JSONSerialization.jsonObject(with: store.controls!) as! [String: Any]
        let controls = after["Controls"] as! [[String: Any]]
        XCTAssertEqual(controls[0]["ControlSize"] as? Int, 2)
        XCTAssertEqual(controls[0]["unknownControl"] as? String, "keep")
        XCTAssertEqual(controls[0]["DisplayName"] as? String, "Greyscale")
        XCTAssertEqual(controls[0]["ControlDescription"] as? String, "Turn the greyscale display filter on or off.")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: controls[1], options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: (before["Controls"] as! [[String: Any]])[1], options: [.sortedKeys]))
    }
    func testIdentifierMigrationKeepsCustomNameAndIsIdempotent() throws {
        let store = FakePreferences(controls: try previousIdentityRegistry(customName: true),
            layout: try fixtureLayout(identifier: "existing"))
        try migratePrevious(store)
        let writes = store.writes
        try migratePrevious(store)
        XCTAssertEqual(store.writes, writes)
        let root = try JSONSerialization.jsonObject(with: store.controls!) as! [String: Any]
        XCTAssertEqual((root["Controls"] as! [[String: Any]])[0]["DisplayName"] as? String, "My customized tile")
    }
    func testIdentifierMigrationRequiresExactPreviousKind() throws {
        let store = FakePreferences(controls: try previousIdentityRegistry(), layout: try fixtureLayout(identifier: "existing"))
        let original = store.controls
        try migratePrevious(store, kind: "local.previous-app.control.unrelated")
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.controls, original)
    }
    func testIdentifierMigrationWriteFailureRestoresExactOriginalBytes() throws {
        let store = FakePreferences(controls: try previousIdentityRegistry(), layout: try fixtureLayout(identifier: "existing"))
        let original = store.controls; let layout = store.layout
        store.failNextControlsWrite = true
        XCTAssertThrowsError(try migratePrevious(store))
        XCTAssertEqual(store.controls, original)
        XCTAssertEqual(store.layout, layout)
    }
    private func legacyRegistry(currentIdentifier: String? = nil) throws -> Data {
        let archiveData = Data(base64Encoded: ControlIdentity.encoded)!
        var archive = try PropertyListSerialization.propertyList(from: archiveData, options: [], format: nil) as! [String: Any]
        archive["$objects"] = (archive["$objects"] as! [Any]).map { object -> Any in
            guard let string = object as? String else { return object }
            return string.replacingOccurrences(of: AppConfiguration.extensionBundleIdentifier,
                                                with: AppConfiguration.legacyExtensionBundleIdentifier)
        }
        let legacy = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0).base64EncodedString()
        XCTAssertTrue(ControlIdentity.ownsLegacy(legacy)); XCTAssertFalse(ControlIdentity.owns(legacy))
        var root = try JSONSerialization.jsonObject(with: fixtureRegistry(identifier: currentIdentifier, lookalike: true)) as! [String: Any]
        var controls = root["Controls"] as! [[String: Any]]
        controls.append(["Identifier": ["legacy"], "ControlIdentity": legacy, "ControlSize": 2, "unknownLegacyField": "keep"])
        root["Controls"] = controls
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
    func testLegacyOnlyTileMigratesWithoutChangingPlacementOrIdentifier() throws {
        let store = FakePreferences(controls: try legacyRegistry(), layout: try fixtureLayout(identifier: "legacy", size: "rect2x1"))
        let originalLayout = store.layout
        let chosen = try ControlCenterTransaction.ensureControl(store: store, preferredIdentifier: nil)
        XCTAssertEqual(chosen, "legacy"); XCTAssertEqual(store.layout, originalLayout)
        XCTAssertEqual(try CustomControlRegistry(data: store.controls).managedIdentifiers, ["legacy"])
        let root = try JSONSerialization.jsonObject(with: store.controls!) as! [String: Any]
        let migrated = (root["Controls"] as! [[String: Any]]).first { ($0["Identifier"] as? [String]) == ["legacy"] }!
        XCTAssertEqual(migrated["ControlSize"] as? Int, 2)
        XCTAssertEqual(migrated["unknownLegacyField"] as? String, "keep")
    }
    func testObsoleteDuplicateIsRemovedWhileCurrentTileIsPreserved() throws {
        let currentPage = try JSONSerialization.jsonObject(with: fixtureLayout(identifier: "current")) as! [[String: Any]]
        let legacyPage = try JSONSerialization.jsonObject(with: fixtureLayout(identifier: "legacy")) as! [[String: Any]]
        let layout = try JSONSerialization.data(withJSONObject: currentPage + legacyPage, options: [.sortedKeys])
        let store = FakePreferences(controls: try legacyRegistry(currentIdentifier: "current"), layout: layout)
        let chosen = try ControlCenterTransaction.ensureControl(store: store, preferredIdentifier: "current")
        XCTAssertEqual(chosen, "current")
        let result = try BentoLayout(data: store.layout)
        XCTAssertTrue(result.contains("current")); XCTAssertFalse(result.contains("legacy"))
        XCTAssertEqual(try CustomControlRegistry(data: store.controls).managedIdentifiers, ["current"])
    }
    func testConcurrentUserEditIsNotOverwritten() throws {
        let store = FakePreferences(controls: try fixtureRegistry(), layout: try fixtureLayout())
        store.mutateOnSecondRead = true
        XCTAssertThrowsError(try ControlCenterTransaction.ensureControl(store: store, preferredIdentifier: nil)) { error in
            guard case ControlCenterError.concurrentEdit = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(store.writes, 0)
        XCTAssertTrue(String(data: store.controls!, encoding: .utf8)!.contains("userEdited"))
    }
    func testUnknownTileSizeFailsWithoutChangingPreferences() throws {
        let store = FakePreferences(controls: try fixtureRegistry(identifier: "ours"),
                                    layout: try fixtureLayout(identifier: "ours", size: "futureSize"))
        let oldControls = store.controls; let oldLayout = store.layout
        XCTAssertThrowsError(try ControlCenterTransaction.update(store: store) { registry, layout in
            try layout.remove(identifiers: registry.removeManagedControls())
        })
        XCTAssertEqual(store.writes, 0); XCTAssertEqual(store.controls, oldControls); XCTAssertEqual(store.layout, oldLayout)
    }
    func testMalformedRegistryShapeIsNotReplacedByEmptyRegistry() throws {
        for bad in ["{}", "{\"Controls\":false}", "{\"Controls\":[1]}"] {
            let store = FakePreferences(controls: Data(bad.utf8), layout: try fixtureLayout())
            XCTAssertThrowsError(try ControlCenterTransaction.ensureControl(store: store, preferredIdentifier: nil))
            XCTAssertEqual(store.writes, 0)
        }
    }
    func testRefreshPreservesIdentifierSizePositionAndUnknownFields() throws {
        let store = FakePreferences(controls: try fixtureRegistry(identifier: "existing"),
                                    layout: try fixtureLayout(identifier: "existing", size: "rect2x1", secondPage: true))
        let oldControls = store.controls; let oldLayout = store.layout
        let first = try ControlCenterTransaction.ensureControl(store: store, preferredIdentifier: "existing")
        let second = try ControlCenterTransaction.ensureControl(store: store, preferredIdentifier: nil)
        XCTAssertEqual(first, "existing"); XCTAssertEqual(second, first)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.controls, oldControls); XCTAssertEqual(store.layout, oldLayout)
    }
    func testMissingLayoutEntryIsRepairedWithoutReplacingRegistry() throws {
        let store = FakePreferences(controls: try fixtureRegistry(identifier: "existing"), layout: try fixtureLayout())
        let oldRegistry = store.controls
        let id = try ControlCenterTransaction.ensureControl(store: store, preferredIdentifier: nil)
        XCTAssertEqual(id, "existing"); XCTAssertEqual(store.controls, oldRegistry)
        XCTAssertTrue(try BentoLayout(data: store.layout).contains("existing"))
        let root = try JSONSerialization.jsonObject(with: store.layout) as! [[String: Any]]
        XCTAssertEqual(root[0]["unknownBox"] as? String, "preserve")
        XCTAssertEqual((root[0]["grid"] as? [String: Any])?["unknownGrid"] as? Int, 99)
    }
    func testCorruptRegistryFailsClosedBeforeAnyWrites() throws {
        let bad = Data("{not json".utf8)
        let store = FakePreferences(controls: bad, layout: try fixtureLayout())
        XCTAssertThrowsError(try ControlCenterTransaction.ensureControl(store: store, preferredIdentifier: nil))
        XCTAssertEqual(store.controls, bad); XCTAssertEqual(store.writes, 0)
    }
    func testCorruptLayoutFailsBeforeRegistryWrite() throws {
        let store = FakePreferences(controls: try fixtureRegistry(), layout: Data("[]".utf8))
        let original = store.controls
        XCTAssertThrowsError(try ControlCenterTransaction.ensureControl(store: store, preferredIdentifier: nil))
        XCTAssertEqual(store.controls, original); XCTAssertEqual(store.writes, 0)
    }
    func testFailedSecondWriteRestoresExactOriginalBlobs() throws {
        let store = FakePreferences(controls: nil, layout: try fixtureLayout()); store.failNextLayoutWrite = true
        let originalLayout = store.layout
        XCTAssertThrowsError(try ControlCenterTransaction.ensureControl(store: store, preferredIdentifier: nil))
        XCTAssertNil(store.controls); XCTAssertEqual(store.layout, originalLayout)
    }
    func testLookalikeThirdPartyTileIsNeverOwnedOrRemoved() throws {
        let store = FakePreferences(controls: try fixtureRegistry(identifier: "ours", lookalike: true),
                                    layout: try fixtureLayout(identifier: "ours", secondPage: true))
        try ControlCenterTransaction.update(store: store) { registry, layout in
            let ids = registry.removeManagedControls(); XCTAssertEqual(ids, ["ours"])
            try layout.remove(identifiers: ids)
        }
        let registry = try CustomControlRegistry(data: store.controls)
        XCTAssertEqual(registry.managedIdentifiers, [])
        let root = try JSONSerialization.jsonObject(with: store.controls!) as! [String: Any]
        let controls = root["Controls"] as! [[String: Any]]
        XCTAssertEqual(controls.count, 1); XCTAssertEqual(controls[0]["Identifier"] as? [String], ["someone-elses-tile"])
        XCTAssertFalse(try BentoLayout(data: store.layout).contains("ours"))
    }
    func testNewInstallIsIdempotent() throws {
        let store = FakePreferences(controls: try fixtureRegistry(lookalike: true), layout: try fixtureLayout())
        let first = try ControlCenterTransaction.ensureControl(store: store, preferredIdentifier: nil, makeIdentifier: { "stable" })
        let afterFirst = store.writes
        let second = try ControlCenterTransaction.ensureControl(store: store, preferredIdentifier: nil)
        XCTAssertEqual(first, "stable"); XCTAssertEqual(second, first); XCTAssertEqual(store.writes, afterFirst)
    }
}
