import Foundation

/// Compare exact stored spelling, including Unicode normalization differences.
enum NoteTextReplacement {
    static func utf16Equal(_ lhs: String, _ rhs: String) -> Bool { lhs.utf16.elementsEqual(rhs.utf16) }
}
