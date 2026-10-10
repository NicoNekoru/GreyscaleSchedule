import Foundation

/// The private Control Centre preferences store uses an NSKeyedArchiver payload
/// containing CHSControlIdentity and CHSExtensionIdentity objects. Keep that
/// compatibility payload isolated here and validate its embedded identifiers
/// before writing it to system preferences.
enum ControlIdentity {
    static let encoded = "YnBsaXN0MDDUAQIDBAUGJSZZJGFyY2hpdmVyWCRvYmplY3RzWCR2ZXJzaW9uVCR0b3BfEA9OU0tleWVkQXJjaGl2ZXKoBwgRGRobISJVJG51bGzUCQoLDA0ODxBZaW50ZW50UmVmVGtpbmRVZXh0SWRWJGNsYXNzgACABoACgAfUEhMUDA0WFxhfEBBkZXZpY2VJZGVudGlmaWVyXxAZY29udGFpbmVyQnVuZGxlSWRlbnRpZmllcl8QGWV4dGVuc2lvbkJ1bmRsZUlkZW50aWZpZXKAAIAEgAOABV8QIWxvY2FsLmdyZXlzY2FsZS1zY2hlZHVsZS5jb250cm9sMl8QGGxvY2FsLmdyZXlzY2FsZS1zY2hlZHVsZdIcHR4fWCRjbGFzc2VzWiRjbGFzc25hbWWiHyBfEBRDSFNFeHRlbnNpb25JZGVudGl0eVhOU09iamVjdF8QK2xvY2FsLmdyZXlzY2FsZS1zY2hlZHVsZS5jb250cm9sMi5ncmV5c2NhbGXSHB0jJKIkIF8QEkNIU0NvbnRyb2xJZGVudGl0eRIAAYag0ScoVHJvb3SAAQAIABEAGwAkAC0AMgBEAE0AUwBcAGYAawBxAHgAegB8AH4AgACJAJwAuADUANYA2ADaANwBAAEbASABKQE0ATcBTgFXAYUBigGNAaIBpwGqAa8AAAAAAAACAQAAAAAAAAApAAAAAAAAAAAAAAAAAAABsQ=="

    static var isValid: Bool {
        owns(encoded)
    }

    static func owns(_ encoded: String?) -> Bool {
        matches(encoded, containerIdentifier: AppConfiguration.bundleIdentifier,
                extensionIdentifier: AppConfiguration.extensionBundleIdentifier, kind: AppConfiguration.controlKind)
    }

    static func ownsLegacy(_ encoded: String?) -> Bool {
        matches(encoded, containerIdentifier: AppConfiguration.bundleIdentifier,
                extensionIdentifier: AppConfiguration.legacyExtensionBundleIdentifier,
                kind: "\(AppConfiguration.legacyExtensionBundleIdentifier).greyscale")
    }

    static func matches(_ encoded: String?, containerIdentifier: String,
                        extensionIdentifier: String, kind: String) -> Bool {
        guard let encoded, let data = Data(base64Encoded: encoded),
              let archive = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any],
              let objects = archive["$objects"] as? [Any]
        else { return false }

        let strings = Set(objects.compactMap { $0 as? String })
        return strings.contains(containerIdentifier)
            && strings.contains(extensionIdentifier)
            && strings.contains(kind)
    }
}
