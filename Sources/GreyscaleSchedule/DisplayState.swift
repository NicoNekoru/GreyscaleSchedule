import Foundation

protocol DisplayFilterBackend {
    func read() throws -> Bool
    func write(_ enabled: Bool) throws
}

enum DisplayStateError: LocalizedError {
    case expired
    case notConfirmed(Bool)
    var errorDescription: String? {
        switch self {
        case .expired: return "The greyscale request expired before it could be applied."
        case .notConfirmed(let enabled):
            return "macOS did not confirm greyscale \(enabled ? "on" : "off")."
        }
    }
}

/// Cancellation is effective up to commit. Once an OS write has started,
/// finish verifying it rather than undoing a newer user's choice.
final class DisplayOperation {
    private let lock = NSLock()
    private var cancelled = false
    private var committed = false
    func cancel() { lock.withLock { cancelled = true } }
    func commit(deadline: TimeInterval, now: TimeInterval) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            guard now < deadline else { throw DisplayStateError.expired }
            committed = true
        }
    }
    var hasCommitted: Bool { lock.withLock { committed } }
}

/// The helper is the only writer. Fresh reads, writes and external-change
/// observations share this queue, so no caller publishes an unconfirmed value.
final class DisplayStateController {
    private let queue = DispatchQueue(label: "local.greyscale-schedule.display-state")
    private let backend: DisplayFilterBackend
    private let changed: (Bool) -> Void
    private let now: () -> TimeInterval
    private let pause: (TimeInterval) -> Void
    private let confirmationTimeout: TimeInterval
    private var observed: Bool?

    init(backend: DisplayFilterBackend, confirmationTimeout: TimeInterval = 3,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         changed: @escaping (Bool) -> Void) {
        self.backend = backend
        self.confirmationTimeout = confirmationTimeout
        self.now = now
        self.pause = pause
        self.changed = changed
    }

    func read(reply: @escaping (Result<Bool, Error>) -> Void) {
        queue.async { reply(Result { try self.observe() }) }
    }

    func set(_ enabled: Bool, deadline: TimeInterval, operation: DisplayOperation,
             reply: @escaping (Result<Bool, Error>) -> Void) {
        queue.async {
            reply(Result {
                let before = try self.observe()
                try operation.commit(deadline: deadline, now: self.now())
                guard before != enabled else { return before }
                try self.backend.write(enabled)
                let confirmationDeadline = self.now() + self.confirmationTimeout
                repeat {
                    let actual = try self.backend.read()
                    if actual == enabled { self.publish(actual); return actual }
                    self.pause(0.05)
                } while self.now() < confirmationDeadline
                _ = try self.observe()
                throw DisplayStateError.notConfirmed(enabled)
            })
        }
    }

    private func observe() throws -> Bool {
        let actual = try backend.read()
        publish(actual)
        return actual
    }
    private func publish(_ actual: Bool) {
        let previous = observed
        observed = actual
        // A restarted helper has no baseline, but the tile may still have an
        // older cached value. Publish the first confirmed snapshot as well.
        if previous != actual { changed(actual) }
    }
}

final class ControlExecutionTracker {
    private let lock = NSLock()
    private var active: Set<UUID> = []
    private var generation: UInt64 = 0
    private var started = false
    var hasStarted: Bool { lock.withLock { started } }
    var activeCount: Int { lock.withLock { active.count } }
    var idleGeneration: UInt64? { lock.withLock { active.isEmpty ? generation : nil } }
    func begin() -> UUID {
        lock.withLock {
            started = true
            generation &+= 1
            let ticket = UUID()
            active.insert(ticket)
            return ticket
        }
    }
    func finish(_ ticket: UUID) -> Bool {
        lock.withLock { active.remove(ticket) != nil && active.isEmpty }
    }
    func isStillIdle(generation expected: UInt64) -> Bool {
        lock.withLock { active.isEmpty && generation == expected }
    }
    func shouldPresentWindow(explicit: Bool, defaultLaunch: Bool) -> Bool {
        // An accessory app need not become active before its first window is
        // shown. Activation follows window presentation, not the other way round.
        explicit || (defaultLaunch && !hasStarted)
    }
}
