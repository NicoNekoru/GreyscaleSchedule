import CoreFoundation
import Darwin
import Foundation

enum DisplayFilterError: LocalizedError {
    case frameworkUnavailable
    case symbolUnavailable(String)
    var errorDescription: String? {
        switch self {
        case .frameworkUnavailable: return "macOS’s greyscale display service is unavailable."
        case .symbolUnavailable(let name):
            return "macOS’s greyscale display service is missing \(name)."
        }
    }
}

/// Private compatibility boundary. Never compiled into the widget.
struct SystemDisplayFilter: DisplayFilterBackend {
    private typealias Read = @convention(c) () -> Bool
    private typealias Write = @convention(c) (Bool) -> Void
    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess",
        RTLD_LAZY | RTLD_LOCAL
    )
    private func function<T>(_ name: String, as type: T.Type) throws -> T {
        guard let handle = Self.handle else { throw DisplayFilterError.frameworkUnavailable }
        guard let symbol = dlsym(handle, name) else { throw DisplayFilterError.symbolUnavailable(name) }
        return unsafeBitCast(symbol, to: type)
    }
    func read() throws -> Bool {
        // macOS 26's migrated filter lives in MediaAccessibility. Synchronize
        // explicitly instead of trusting the long-lived UniversalAccess cache.
        let domain = "com.apple.mediaaccessibility" as CFString
        if CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
           let enabled = CFPreferencesCopyValue(
                "__Color__-MADisplayFilterCategoryEnabled" as CFString, domain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost
           ) as? NSNumber,
           let type = CFPreferencesCopyValue(
                "__Color__-MADisplayFilterType" as CFString, domain,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost
           ) as? NSNumber {
            return enabled.boolValue && type.intValue == 1
        }
        let read = try function("UAGrayscaleIsEnabled", as: Read.self)
        return read()
    }
    func write(_ enabled: Bool) throws {
        let write = try function("UAGrayscaleSetEnabled", as: Write.self)
        write(enabled)
    }
}
