import CoreFoundation
import Foundation

enum ControlCenterError: LocalizedError {
    case invalidIdentity
    case invalidPreferences
    case preferenceWriteFailed
    case concurrentEdit
    case rollbackFailed(String)
    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "The bundled Control Centre identity does not match this app."
        case .invalidPreferences: return "Control Centre’s layout data could not be read. No controls were changed."
        case .preferenceWriteFailed: return "Control Centre’s preferences could not be saved."
        case .concurrentEdit: return "Control Centre changed during installation. Please try again."
        case .rollbackFailed(let detail): return "Control Centre’s previous layout could not be restored. \(detail)"
        }
    }
}

protocol ControlCenterPreferenceStore {
    func readControls() throws -> Data?
    func readLayout() throws -> Data
    func writeControls(_ data: Data?) throws
    func writeLayout(_ data: Data) throws
}

struct SystemControlCenterPreferences: ControlCenterPreferenceStore {
    private let controlsDomain = "com.apple.controlcenter" as CFString
    private let bentoDomain = "com.apple.controlcenter.bentoboxes" as CFString
    private let controlsKey = "ControlCenterDisplayableChronoControlsProviderConfiguration"

    private func read(_ key: String, domain: CFString, host: CFString) throws -> Data? {
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, host) else {
            throw ControlCenterError.invalidPreferences
        }
        guard let value = CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, host) else { return nil }
        guard let data = value as? Data else { throw ControlCenterError.invalidPreferences }
        return data
    }
    private func write(_ data: Data?, key: String, domain: CFString, host: CFString) throws {
        CFPreferencesSetValue(key as CFString, data as CFPropertyList?, domain, kCFPreferencesCurrentUser, host)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, host) else {
            throw ControlCenterError.preferenceWriteFailed
        }
    }
    func readControls() throws -> Data? { try read(controlsKey, domain: controlsDomain, host: kCFPreferencesAnyHost) }
    func readLayout() throws -> Data {
        guard let data = try read("boxes", domain: bentoDomain, host: kCFPreferencesCurrentHost) else {
            throw ControlCenterError.invalidPreferences
        }
        return data
    }
    func writeControls(_ data: Data?) throws { try write(data, key: controlsKey, domain: controlsDomain, host: kCFPreferencesAnyHost) }
    func writeLayout(_ data: Data) throws { try write(data, key: "boxes", domain: bentoDomain, host: kCFPreferencesCurrentHost) }
}

private enum PropertyListCodec {
    static func decode(_ data: Data) throws -> Any {
        try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
    static func encode(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
}

private struct GridPoint: Hashable {
    let x: Int
    let y: Int
    init(x: Int, y: Int) { self.x = x; self.y = y }
    init?(_ value: [String: Any]) {
        guard let x = value["x"] as? Int, let y = value["y"] as? Int else { return nil }
        self.x = x; self.y = y
    }
    var dictionary: [String: Any] { ["x": x, "y": y] }
    static func order(_ a: GridPoint, _ b: GridPoint) -> Bool { a.y == b.y ? a.x < b.x : a.y < b.y }
}

private struct BentoPage {
    private var box: [String: Any]
    private var wrapper: [String: Any]
    private var controls: [[String: Any]]
    private var grid: [String: Any]
    init(box: [String: Any]) throws {
        guard let encoded = box["displayablesData"] as? String,
              let data = Data(base64Encoded: encoded),
              let wrapper = try PropertyListCodec.decode(data) as? [String: Any],
              let controlData = wrapper["chronoControls"] as? Data,
              let controls = try PropertyListCodec.decode(controlData) as? [[String: Any]],
              let grid = box["grid"] as? [String: Any],
              grid["elements"] is [[String: Any]],
              let width = grid["width"] as? Int, (1...32).contains(width),
              let height = grid["maxHeight"] as? Int, (1...512).contains(height) else {
            throw ControlCenterError.invalidPreferences
        }
        for key in ["allLocations", "occupiedLocations", "unoccupiedLocations"] {
            guard let points = grid[key] as? [[String: Any]],
                  points.allSatisfy({ GridPoint($0) != nil }) else { throw ControlCenterError.invalidPreferences }
        }
        self.box = box; self.wrapper = wrapper; self.controls = controls; self.grid = grid
    }
    private var elements: [[String: Any]] {
        get { grid["elements"] as! [[String: Any]] }
        set { grid["elements"] = newValue }
    }
    private func points(_ key: String) -> Set<GridPoint> {
        Set((grid[key] as! [[String: Any]]).compactMap(GridPoint.init))
    }
    private mutating func setPoints(_ value: Set<GridPoint>, _ key: String) {
        grid[key] = value.sorted(by: GridPoint.order).map(\.dictionary)
    }
    private static func identifier(_ value: Any?) -> String? { (value as? [String: Any])?["rawValue"] as? String }
    func contains(_ identifier: String) -> Bool {
        controls.contains { $0["rawValue"] as? String == identifier }
            && elements.contains { Self.identifier($0["id"]) == identifier }
    }
    func hasElement(_ identifier: String) -> Bool { elements.contains { Self.identifier($0["id"]) == identifier } }

    mutating func remove(_ identifiers: Set<String>) throws {
        controls.removeAll { identifiers.contains($0["rawValue"] as? String ?? "") }
        if let data = wrapper["modules"] {
            guard let data = data as? Data,
                  var modules = try PropertyListCodec.decode(data) as? [[String: Any]] else { throw ControlCenterError.invalidPreferences }
            modules.removeAll { identifiers.contains(Self.identifier($0["id"]) ?? "") }
            wrapper["modules"] = try PropertyListCodec.encode(modules)
        }
        if let ids = wrapper["instanceIds"] {
            guard var ids = ids as? [[String: Any]] else { throw ControlCenterError.invalidPreferences }
            ids.removeAll { identifiers.contains($0["rawValue"] as? String ?? "") }
            wrapper["instanceIds"] = ids
        }
        let removed = elements.filter { identifiers.contains(Self.identifier($0["id"]) ?? "") }
        elements.removeAll { identifiers.contains(Self.identifier($0["id"]) ?? "") }
        var occupied = points("occupiedLocations")
        var unoccupied = points("unoccupiedLocations")
        let retainedCells = try Set(elements.flatMap(Self.cells))
        for element in removed {
            for cell in try Self.cells(element) where !retainedCells.contains(cell) {
                occupied.remove(cell); unoccupied.insert(cell)
            }
        }
        setPoints(occupied, "occupiedLocations"); setPoints(unoccupied, "unoccupiedLocations")
    }

    private static func cells(_ element: [String: Any]) throws -> [GridPoint] {
        guard let location = element["location"] as? [String: Any], let origin = GridPoint(location),
              let size = element["size"] as? [String: Any], size.count == 1,
              let name = size.keys.first else { throw ControlCenterError.invalidPreferences }
        // Fail closed for a future size representation instead of freeing only
        // one row and accidentally occupying another control's cells.
        let dimensions = name.replacingOccurrences(of: "square", with: "")
            .replacingOccurrences(of: "rect", with: "").split(separator: "x").compactMap { Int($0) }
        guard (name.hasPrefix("square") || name.hasPrefix("rect")), dimensions.count == 2,
              dimensions.allSatisfy({ (1...32).contains($0) }) else { throw ControlCenterError.invalidPreferences }
        return (0..<dimensions[1]).flatMap { y in
            (0..<dimensions[0]).map { GridPoint(x: origin.x + $0, y: origin.y + y) }
        }
    }

    mutating func add(_ identifier: String) {
        if !controls.contains(where: { $0["rawValue"] as? String == identifier }) { controls.append(["rawValue": identifier]) }
        var ids = wrapper["instanceIds"] as? [[String: Any]] ?? []
        if !ids.contains(where: { $0["rawValue"] as? String == identifier }) {
            ids.append(["rawValue": identifier]); wrapper["instanceIds"] = ids
        }
        guard !hasElement(identifier) else { return }
        let point = firstFreeCell()
        elements.append(["size": ["square1x1": [:]], "location": point.dictionary, "id": ["rawValue": identifier]])
        var occupied = points("occupiedLocations"); occupied.insert(point)
        var unoccupied = points("unoccupiedLocations"); unoccupied.remove(point)
        setPoints(occupied, "occupiedLocations"); setPoints(unoccupied, "unoccupiedLocations")
    }
    private mutating func firstFreeCell() -> GridPoint {
        let width = grid["width"] as! Int
        let height = grid["maxHeight"] as! Int
        let occupied = points("occupiedLocations")
        for y in 0..<height { for x in 0..<width {
            let point = GridPoint(x: x, y: y)
            if !occupied.contains(point) { return point }
        } }
        grid["maxHeight"] = height + 1
        var all = points("allLocations"); var unoccupied = points("unoccupiedLocations")
        for x in 0..<width { let point = GridPoint(x: x, y: height); all.insert(point); unoccupied.insert(point) }
        setPoints(all, "allLocations"); setPoints(unoccupied, "unoccupiedLocations")
        return GridPoint(x: 0, y: height)
    }
    func encodedBox() throws -> [String: Any] {
        var output = box; var wrapper = wrapper
        wrapper["chronoControls"] = try PropertyListCodec.encode(controls)
        output["displayablesData"] = try PropertyListCodec.encode(wrapper).base64EncodedString()
        output["grid"] = grid
        return output
    }
}

struct BentoLayout {
    private var pages: [BentoPage]
    init(data: Data) throws {
        guard let boxes = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !boxes.isEmpty else {
            throw ControlCenterError.invalidPreferences
        }
        pages = try boxes.map(BentoPage.init)
    }
    func contains(_ id: String) -> Bool { pages.contains { $0.contains(id) } }
    mutating func remove(identifiers: Set<String>) throws {
        guard !identifiers.isEmpty else { return }
        for i in pages.indices { try pages[i].remove(identifiers) }
    }
    mutating func add(identifier: String) {
        let index = pages.firstIndex { $0.hasElement(identifier) } ?? 0
        pages[index].add(identifier)
    }
    func encoded() throws -> Data {
        try JSONSerialization.data(withJSONObject: pages.map { try $0.encodedBox() }, options: [.sortedKeys])
    }
}

struct CustomControlRegistry {
    private var root: [String: Any]
    init(data: Data?) throws {
        guard let data else { root = ["Controls": [[String: Any]]()]; return }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["Controls"] is [[String: Any]] else { throw ControlCenterError.invalidPreferences }
        self.root = root
    }
    private var controls: [[String: Any]] {
        get { root["Controls"] as! [[String: Any]] }
        set { root["Controls"] = newValue }
    }
    var managedIdentifiers: [String] {
        controls.filter { ControlIdentity.owns($0["ControlIdentity"] as? String) }
            .flatMap { $0["Identifier"] as? [String] ?? [] }
    }
    mutating func removeManagedControls() -> Set<String> {
        let owned = controls.filter {
            ControlIdentity.owns($0["ControlIdentity"] as? String) || ControlIdentity.ownsLegacy($0["ControlIdentity"] as? String)
        }
        let identifiers = Set(owned.flatMap { $0["Identifier"] as? [String] ?? [] })
        controls.removeAll {
            ControlIdentity.owns($0["ControlIdentity"] as? String) || ControlIdentity.ownsLegacy($0["ControlIdentity"] as? String)
        }
        return identifiers
    }
    mutating func migrateLegacyControls() -> Set<String> {
        var removed: Set<String> = []
        var updated = controls
        var hasCurrent = !managedIdentifiers.isEmpty
        updated = updated.compactMap { control in
            guard ControlIdentity.ownsLegacy(control["ControlIdentity"] as? String) else { return control }
            if !hasCurrent, !(control["Identifier"] as? [String] ?? []).isEmpty {
                hasCurrent = true
                var migrated = control
                migrated["ControlIdentity"] = ControlIdentity.encoded
                return migrated
            }
            removed.formUnion(control["Identifier"] as? [String] ?? [])
            return nil
        }
        controls = updated
        return removed
    }
    mutating func add(identifier: String) {
        controls.append(["ControlSize": 0, "ControlType": 1, "ControlIdentity": ControlIdentity.encoded,
                         "DisplayName": "Greyscale", "OverrideSizeForMenuBar": false, "Identifier": [identifier],
                         "ControlDescription": "Turn the greyscale display filter on or off.", "PromptsForUserConfiguration": false])
    }
    func encoded() throws -> Data { try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) }
}

/// Decode and plan both blobs before touching either. Roll back the exact
/// original bytes (including unknown fields) if either preference write fails.
enum ControlCenterTransaction {
    static func update(store: ControlCenterPreferenceStore,
                       plan: (inout CustomControlRegistry, inout BentoLayout) throws -> Void) throws {
        let oldControls = try store.readControls(); let oldLayout = try store.readLayout()
        var registry = try CustomControlRegistry(data: oldControls)
        var layout = try BentoLayout(data: oldLayout)
        let initialControls = try registry.encoded(); let initialLayout = try layout.encoded()
        try plan(&registry, &layout)
        let controls = try registry.encoded(); let boxes = try layout.encoded()
        let changedControls = controls != initialControls; let changedLayout = boxes != initialLayout
        guard changedControls || changedLayout else { return }
        guard try store.readControls() == oldControls, try store.readLayout() == oldLayout else { throw ControlCenterError.concurrentEdit }
        do {
            if changedControls { try store.writeControls(controls) }
            if changedLayout { try store.writeLayout(boxes) }
        } catch {
            let originalError = error
            do {
                if changedLayout { try store.writeLayout(oldLayout) }
                if changedControls { try store.writeControls(oldControls) }
            } catch { throw ControlCenterError.rollbackFailed(error.localizedDescription) }
            throw originalError
        }
    }

    static func ensureControl(store: ControlCenterPreferenceStore, preferredIdentifier: String?,
                              makeIdentifier: () -> String = { UUID().uuidString.uppercased() }) throws -> String {
        var chosen = ""
        try update(store: store) { registry, layout in
            try layout.remove(identifiers: registry.migrateLegacyControls())
            let identifiers = registry.managedIdentifiers
            chosen = preferredIdentifier.flatMap { identifiers.contains($0) ? $0 : nil }
                ?? identifiers.first ?? makeIdentifier()
            if !identifiers.contains(chosen) { registry.add(identifier: chosen) }
            if !layout.contains(chosen) { layout.add(identifier: chosen) }
        }
        return chosen
    }
}

enum ControlCenterIntegration {
    private static let legacyOwnershipKey = "ownsAccessibilityShortcutsControl"
    private static let legacyIdentifierKey = "accessibilityShortcutsControlIdentifier"
    private static let nativeIdentifierKey = "nativeControlIdentifier"
    private static let preferences = SystemControlCenterPreferences()
    private static let launchServices = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    private static var extensionURL: URL? { Bundle.main.builtInPlugInsURL?.appendingPathComponent("GreyscaleControl.appex") }

    static func install() throws {
        guard ControlIdentity.isValid else { throw ControlCenterError.invalidIdentity }
        // Validate before registration or helper changes, not after deleting a tile.
        _ = try CustomControlRegistry(data: preferences.readControls())
        _ = try BentoLayout(data: preferences.readLayout())
        try ControlRequestAgent.install()
        try registerExtension()
        try ProcessRunner.checked("/usr/bin/pluginkit", ["-e", "ignore", "-i", AppConfiguration.legacyExtensionBundleIdentifier])
        try removeLegacyAccessibilityShortcut()
        let id = try ControlCenterTransaction.ensureControl(store: preferences,
            preferredIdentifier: UserDefaults.standard.string(forKey: nativeIdentifierKey))
        UserDefaults.standard.set(id, forKey: nativeIdentifierKey)
        restartControlCenter()
    }
    static func remove() throws {
        try ControlCenterTransaction.update(store: preferences) { registry, layout in
            try layout.remove(identifiers: registry.removeManagedControls())
        }
        UserDefaults.standard.removeObject(forKey: nativeIdentifierKey)
        try removeLegacyAccessibilityShortcut()
        restartControlCenter()
    }
    static var isInstalled: Bool {
        guard let registry = try? CustomControlRegistry(data: preferences.readControls()),
              let layout = try? BentoLayout(data: preferences.readLayout()) else { return false }
        return registry.managedIdentifiers.contains { layout.contains($0) }
    }
    static func registerExtension() throws {
        guard let url = extensionURL else { throw CocoaError(.fileNoSuchFile) }
        try ProcessRunner.checked(launchServices, ["-f", Bundle.main.bundleURL.path])
        try ProcessRunner.checked("/usr/bin/pluginkit", ["-a", url.path])
    }
    static func unregisterExtension() throws {
        guard let url = extensionURL else { throw CocoaError(.fileNoSuchFile) }
        try ProcessRunner.checked("/usr/bin/pluginkit", ["-r", url.path])
        try ProcessRunner.checked(launchServices, ["-u", Bundle.main.bundleURL.path])
    }
    static func removeLegacyAccessibilityShortcut() throws {
        guard UserDefaults.standard.bool(forKey: legacyOwnershipKey),
              let id = UserDefaults.standard.string(forKey: legacyIdentifierKey) else { return }
        try ControlCenterTransaction.update(store: preferences) { _, layout in try layout.remove(identifiers: [id]) }
        UserDefaults.standard.removeObject(forKey: legacyOwnershipKey)
        UserDefaults.standard.removeObject(forKey: legacyIdentifierKey)
    }
    private static func restartControlCenter() { ProcessRunner.run("/usr/bin/killall", ["ControlCenter"]) }
}
