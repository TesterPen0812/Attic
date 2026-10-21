import Foundation
import SwiftData

/// The colour a tag was given (colour pass, owner 2026-10-10).
///
/// Tags themselves are strings stored on each item (`AtticTag`), with no tag
/// table; this entity records only a tag name's colour, so a tag never
/// changes colour by itself: renaming carries it, the tag menu changes it.
///
/// Additive and CloudKit-compatible: every attribute is defaulted or
/// optional and nothing is unique. Several rows can hold the same name (a
/// replica, or two devices that gave a new tag its colour at once):
/// presentation picks one deterministically (`TagColourStore.storedHues`),
/// and a change writes every one of them.
@Model final class TagColour {
    var id: UUID = UUID()
    /// The tag's normalised name (`AtticTag.normalize`).
    var name: String = ""
    /// `AtticTagHue.rawValue`; nil until a colour is given. A value this
    /// version doesn't know (a newer Attic's hue) is kept, never rewritten.
    var colourKey: String?
    var createdAt: Date = Date()
    /// When the colour last changed: the newest change wins among replicas.
    var modifiedAt: Date = Date()

    init(id: UUID = UUID(), name: String, hue: AtticTagHue?, at date: Date = Date()) {
        self.id = id
        self.name = name
        colourKey = hue?.rawValue
        createdAt = date
        modifiedAt = date
    }

    var hue: AtticTagHue? { colourKey.flatMap(AtticTagHue.init(rawValue:)) }
}
