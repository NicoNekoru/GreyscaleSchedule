import Foundation

/// The private Control Centre preferences store uses an NSKeyedArchiver payload
/// containing CHSControlIdentity and CHSExtensionIdentity objects. Keep that
/// compatibility payload isolated here and validate its embedded identifiers
/// before writing it to system preferences.
enum ControlIdentity {
    static let encoded = "YnBsaXN0MDDUAQIDBAUGCQpYJHZlcnNpb25UJHRvcFkkYXJjaGl2ZXJYJG9iamVjdHMSAAGGoNEHCFRyb290gAFfEA9OU0tleWVkQXJjaGl2ZXKoCwwVHR4fJSZVJG51bGzUDQ4PEBESExRZaW50ZW50UmVmVGtpbmRVZXh0SWRWJGNsYXNzgACABoACgAfUFhcYEBEaGxxfEBBkZXZpY2VJZGVudGlmaWVyXxAZY29udGFpbmVyQnVuZGxlSWRlbnRpZmllcl8QGWV4dGVuc2lvbkJ1bmRsZUlkZW50aWZpZXKAAIAEgAOABV8QIWxvY2FsLmdyZXlzY2FsZS1zY2hlZHVsZS5jb250cm9sMl8QGGxvY2FsLmdyZXlzY2FsZS1zY2hlZHVsZdIgISIjWCRjbGFzc2VzWiRjbGFzc25hbWWiIyRfEBRDSFNFeHRlbnNpb25JZGVudGl0eVhOU09iamVjdF8QK2xvY2FsLmdyZXlzY2FsZS1zY2hlZHVsZS5jb250cm9sMi5ncmV5c2NhbGXSICEnKKIoJF8QEkNIU0NvbnRyb2xJZGVudGl0eQAIABEAGgAfACkAMgA3ADoAPwBBAFMAXABiAGsAdQB6AIAAhwCJAIsAjQCPAJgAqwDHAOMA5QDnAOkA6wEPASoBLwE4AUMBRgFdAWYBlAGZAZwAAAAAAAACAQAAAAAAAAApAAAAAAAAAAAAAAAAAAABsQ=="

    static var isValid: Bool {
        owns(encoded)
    }

    static func owns(_ encoded: String?) -> Bool {
        matches(encoded, extensionIdentifier: AppConfiguration.extensionBundleIdentifier)
    }

    static func ownsLegacy(_ encoded: String?) -> Bool {
        matches(encoded, extensionIdentifier: AppConfiguration.legacyExtensionBundleIdentifier)
    }

    private static func matches(_ encoded: String?, extensionIdentifier: String) -> Bool {
        guard let encoded, let data = Data(base64Encoded: encoded),
              let archive = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any],
              let objects = archive["$objects"] as? [Any]
        else { return false }

        let strings = Set(objects.compactMap { $0 as? String })
        return strings.contains(AppConfiguration.bundleIdentifier)
            && strings.contains(extensionIdentifier)
            && strings.contains("\(extensionIdentifier).greyscale")
    }
}
