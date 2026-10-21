import Foundation

enum PreviewIdentity {
    static func isPreview(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        let prefix = "com.taha.Attic.preview."
        return identifier.hasPrefix(prefix) && identifier.count > prefix.count
    }
}
