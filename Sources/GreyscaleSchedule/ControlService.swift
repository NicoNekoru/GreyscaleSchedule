import Foundation
import Security
import WidgetKit

/// macOS may discard an external reload while the control is hidden. Keep one
/// pending refresh until the value provider has actually sampled fresh state.
/// Ordinary app/status reads must not acknowledge a tile refresh.
final class ControlRefreshCoordinator {
    private let lock = NSLock()
    private let reload: () -> Void
    private let scheduleRetry: (@escaping () -> Void) -> Void
    private let shouldRetry: () -> Bool
    private var pending: Bool?
    private var retryScheduled = false

    init(reload: @escaping () -> Void, shouldRetry: @escaping () -> Bool = { true },
         scheduleRetry: @escaping (@escaping () -> Void) -> Void = { retry in
             DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: retry)
         }) {
        self.reload = reload
        self.shouldRetry = shouldRetry
        self.scheduleRetry = scheduleRetry
    }

    func request(_ actual: Bool) {
        let needsRetry = lock.withLock {
            pending = actual
            guard !retryScheduled else { return false }
            retryScheduled = true
            return true
        }
        reload()
        if needsRetry { enqueueRetry() }
    }

    @discardableResult
    func sampled(_ actual: Bool) -> Bool {
        lock.withLock {
            guard pending == actual else { return false }
            pending = nil
            return true
        }
    }

    private func enqueueRetry() {
        scheduleRetry { [weak self] in self?.retry() }
    }

    private func retry() {
        let installed = shouldRetry()
        let needsReload = lock.withLock {
            guard pending != nil, installed else {
                pending = nil
                retryScheduled = false
                return false
            }
            return true
        }
        guard needsReload else { return }
        reload()
        enqueueRetry()
    }
}

final class ControlServiceSession: NSObject, GreyscaleControlServiceProtocol {
    private let controller: DisplayStateController
    private let refresh: ControlRefreshCoordinator?
    private let lock = NSLock()
    private var operations: [String: DisplayOperation] = [:]
    private var cancelledIdentifiers: Set<String> = []
    private var invalidated = false
    private let record: (String) -> Void
    init(controller: DisplayStateController, refresh: ControlRefreshCoordinator? = nil,
         record: @escaping (String) -> Void = { _ in }) {
        self.controller = controller
        self.refresh = refresh
        self.record = record
    }
    func read(reply: @escaping (Bool, String?) -> Void) {
        controller.read { Self.respond($0, reply: reply) }
    }
    func readForControl(reply: @escaping (Bool, String?) -> Void) {
        controller.read { result in
            if case .success(let actual) = result, self.refresh?.sampled(actual) == true {
                self.record("Tile sampled pending greyscale \(actual ? "on" : "off"); refresh acknowledged")
            }
            Self.respond(result, reply: reply)
        }
    }
    func set(_ enabled: Bool, identifier: String, deadline: Double,
             reply: @escaping (Bool, String?) -> Void) {
        let operation = DisplayOperation()
        lock.withLock {
            if invalidated || cancelledIdentifiers.remove(identifier) != nil { operation.cancel() }
            operations[identifier] = operation
        }
        let now = ProcessInfo.processInfo.systemUptime
        let boundedDeadline = deadline.isFinite ? min(deadline, now + 15) : now
        controller.set(enabled, deadline: boundedDeadline, operation: operation) { result in
            self.lock.withLock { _ = self.operations.removeValue(forKey: identifier) }
            self.record("Control request \(identifier) \(result)")
            Self.respond(result, reply: reply)
        }
    }
    func cancel(_ identifier: String) {
        lock.withLock {
            if let operation = operations[identifier] { operation.cancel() }
            else { cancelledIdentifiers.insert(identifier) }
        }
    }
    func invalidate() {
        lock.withLock {
            invalidated = true
            operations.values.forEach { $0.cancel() }
        }
    }
    private static func respond(_ result: Result<Bool, Error>, reply: (Bool, String?) -> Void) {
        switch result {
        case .success(let value): reply(value, nil)
        case .failure(let error): reply(false, error.localizedDescription)
        }
    }
}

final class ControlServiceHost: NSObject, NSXPCListenerDelegate {
    private let controller: DisplayStateController
    private let refresh: ControlRefreshCoordinator?
    private let listener: NSXPCListener
    private let requireSignedPeer: Bool
    private var timer: DispatchSourceTimer?
    init(controller: DisplayStateController, listener: NSXPCListener, requireSignedPeer: Bool = true,
         refresh: ControlRefreshCoordinator? = nil) {
        self.controller = controller
        self.refresh = refresh
        self.listener = listener
        self.requireSignedPeer = requireSignedPeer
        super.init()
        listener.delegate = self
    }
    func start() throws {
        if requireSignedPeer {
            var code: SecCode?
            var staticCode: SecStaticCode?
            var information: CFDictionary?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
                  SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                  SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                                &information) == errSecSuccess,
                  let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
                  team.range(of: "^[A-Z0-9]+$", options: .regularExpression) != nil else {
                throw ControlRequestError.unavailable("The helper must be signed with an Apple Development team.")
            }
            listener.setConnectionCodeSigningRequirement(
                "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and " +
                "(identifier \"\(AppConfiguration.bundleIdentifier)\" or " +
                "identifier \"\(AppConfiguration.extensionBundleIdentifier)\")"
            )
        }
        listener.resume()
    }
    func observeExternalChanges() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [controller] in
            controller.read { result in
                if case .failure(let error) = result {
                    ControlDiagnostics.record("Display state read failed: \(error.localizedDescription)")
                }
            }
        }
        self.timer = timer
        timer.resume()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard !requireSignedPeer || connection.effectiveUserIdentifier == getuid() else { return false }
        let session = ControlServiceSession(controller: controller, refresh: refresh,
            record: requireSignedPeer ? ControlDiagnostics.record : { _ in })
        connection.exportedInterface = NSXPCInterface(with: GreyscaleControlServiceProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { session.invalidate() }
        connection.interruptionHandler = { session.invalidate() }
        connection.resume()
        return true
    }
    static func run() throws -> Never {
        let refresh = ControlRefreshCoordinator(reload: {
            ControlCenter.shared.reloadControls(ofKind: AppConfiguration.controlKind)
        }, shouldRetry: { ControlCenterIntegration.isInstalled })
        let controller = DisplayStateController(backend: SystemDisplayFilter()) { actual in
            ControlDiagnostics.record("Confirmed greyscale \(actual ? "on" : "off"); refreshing control")
            refresh.request(actual)
        }
        let host = ControlServiceHost(controller: controller,
            listener: NSXPCListener(machServiceName: AppConfiguration.controlAgentLabel), refresh: refresh)
        try host.start()
        host.observeExternalChanges()
        ControlDiagnostics.record("Greyscale state service ready")
        withExtendedLifetime(host) { dispatchMain() }
    }
}
