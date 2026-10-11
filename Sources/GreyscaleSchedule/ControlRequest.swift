import Foundation
import OSLog

enum ControlDiagnostics {
    private static let logger = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "ControlIntent")
    private static let lock = NSLock()
    static func event(_ message: String) { logger.notice("\(message, privacy: .public)") }
    static func record(_ message: String) {
        event(message)
        lock.withLock {
            let line = "\(ISO8601DateFormatter().string(from: Date())) [pid \(getpid())] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let manager = FileManager.default
            try? manager.createDirectory(at: AppPaths.log.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: AppPaths.log.path) {
                manager.createFile(atPath: AppPaths.log.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: AppPaths.log) else { return }
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: data) }
            catch { logger.error("Log write failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

enum ControlIntentExecutionState {
    static let didFinishNotification = Notification.Name("\(AppConfiguration.bundleIdentifier).control-intent-idle")
    static let tracker = ControlExecutionTracker()
    static func begin() -> UUID { tracker.begin() }
    static func finish(_ ticket: UUID) {
        if tracker.finish(ticket) {
            NotificationCenter.default.post(name: didFinishNotification, object: nil)
        }
    }
}

@objc protocol GreyscaleControlServiceProtocol {
    func read(reply: @escaping (Bool, String?) -> Void)
    func readForControl(reply: @escaping (Bool, String?) -> Void)
    func set(_ enabled: Bool, identifier: String, deadline: Double, reply: @escaping (Bool, String?) -> Void)
    func cancel(_ identifier: String)
}

enum ControlRequestError: LocalizedError {
    case timedOut
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .timedOut: return "The greyscale helper did not respond in time."
        case .unavailable(let detail): return "The greyscale helper could not complete the request. \(detail)"
        }
    }
}

/// Reads and writes use one service. A failed read remains an error, never a
/// fabricated 'off' value or a persisted UI toggle value.
final class ControlClient {
    static let shared = ControlClient()
    private let makeConnection: () -> NSXPCConnection
    private let timeout: TimeInterval
    init(timeout: TimeInterval = 15, makeConnection: @escaping () -> NSXPCConnection = {
        NSXPCConnection(machServiceName: AppConfiguration.controlAgentLabel)
    }) {
        self.timeout = timeout
        self.makeConnection = makeConnection
    }
    func read() async throws -> Bool { try await request(enabled: nil) }
    func readForControl() async throws -> Bool { try await request(enabled: nil, forControl: true) }
    @discardableResult
    func set(_ enabled: Bool) async throws -> Bool { try await request(enabled: enabled) }

    private func request(enabled: Bool?, forControl: Bool = false) async throws -> Bool {
        let pending = PendingControlReply()
        let identifier = UUID().uuidString
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending.start(continuation) else { return }
                let connection = makeConnection()
                connection.remoteObjectInterface = NSXPCInterface(with: GreyscaleControlServiceProtocol.self)
                connection.interruptionHandler = {
                    pending.finish(.failure(ControlRequestError.unavailable("Connection interrupted.")))
                }
                connection.invalidationHandler = {
                    pending.finish(.failure(ControlRequestError.unavailable("Connection invalidated.")))
                }
                guard pending.attach(connection, identifier: identifier) else {
                    connection.invalidate()
                    return
                }
                connection.resume()
                let timeoutWork = DispatchWorkItem { pending.finish(.failure(ControlRequestError.timedOut)) }
                pending.attach(timeoutWork)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
                guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in
                    pending.finish(.failure(ControlRequestError.unavailable(error.localizedDescription)))
                }) as? GreyscaleControlServiceProtocol else {
                    pending.finish(.failure(ControlRequestError.unavailable("Invalid service interface.")))
                    return
                }
                let reply: (Bool, String?) -> Void = { actual, error in
                    if let error { pending.finish(.failure(ControlRequestError.unavailable(error))) }
                    else { pending.finish(.success(actual)) }
                }
                if let enabled { remote.set(enabled, identifier: identifier, deadline: deadline, reply: reply) }
                else if forControl { remote.readForControl(reply: reply) }
                else { remote.read(reply: reply) }
            }
        } onCancel: { pending.finish(.failure(CancellationError())) }
    }
}

/// Reply, timeout, interruption and cancellation compete to resume exactly
/// once, including when cancellation precedes continuation installation.
final class PendingControlReply {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Error>?
    private var result: Result<Bool, Error>?
    private var connection: NSXPCConnection?
    private var identifier: String?
    private var timeoutWork: DispatchWorkItem?
    func start(_ continuation: CheckedContinuation<Bool, Error>) -> Bool {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return false }
        self.continuation = continuation
        lock.unlock()
        return true
    }
    func attach(_ connection: NSXPCConnection, identifier: String) -> Bool {
        lock.withLock {
            guard result == nil else { return false }
            self.connection = connection
            self.identifier = identifier
            return true
        }
    }
    func attach(_ work: DispatchWorkItem) {
        lock.withLock { if result == nil { timeoutWork = work } else { work.cancel() } }
    }
    func finish(_ value: Result<Bool, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = self.continuation
        self.continuation = nil
        let connection = self.connection
        self.connection = nil
        let identifier = self.identifier
        timeoutWork?.cancel()
        timeoutWork = nil
        lock.unlock()
        if case .failure = value, let connection, let identifier {
            (connection.remoteObjectProxyWithErrorHandler { _ in } as? GreyscaleControlServiceProtocol)?.cancel(identifier)
        }
        connection?.invalidate()
        continuation?.resume(with: value)
    }
}
