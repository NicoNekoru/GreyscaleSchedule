import Foundation
import Security
import WidgetKit

final class ControlServiceSession: NSObject, GreyscaleControlServiceProtocol {
    private let controller: DisplayStateController
    private let lock = NSLock()
    private var operations: [String: DisplayOperation] = [:]
    private var cancelledIdentifiers: Set<String> = []
    private var invalidated = false
    private let record: (String) -> Void
    init(controller: DisplayStateController, record: @escaping (String) -> Void = { _ in }) {
        self.controller = controller
        self.record = record
    }
    func read(reply: @escaping (Bool, String?) -> Void) {
        controller.read { Self.respond($0, reply: reply) }
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
    private let listener: NSXPCListener
    private let requireSignedPeer: Bool
    private var timer: DispatchSourceTimer?
    init(controller: DisplayStateController, listener: NSXPCListener, requireSignedPeer: Bool = true) {
        self.controller = controller
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
        let session = ControlServiceSession(controller: controller,
            record: requireSignedPeer ? ControlDiagnostics.record : { _ in })
        connection.exportedInterface = NSXPCInterface(with: GreyscaleControlServiceProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { session.invalidate() }
        connection.interruptionHandler = { session.invalidate() }
        connection.resume()
        return true
    }
    static func run() throws -> Never {
        let controller = DisplayStateController(backend: SystemDisplayFilter()) { actual in
            ControlDiagnostics.record("Confirmed greyscale \(actual ? "on" : "off"); refreshing control")
            ControlCenter.shared.reloadControls(ofKind: AppConfiguration.controlKind)
        }
        let host = ControlServiceHost(controller: controller,
            listener: NSXPCListener(machServiceName: AppConfiguration.controlAgentLabel))
        try host.start()
        host.observeExternalChanges()
        ControlDiagnostics.record("Greyscale state service ready")
        withExtendedLifetime(host) { dispatchMain() }
    }
}
