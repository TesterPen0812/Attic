import AppKit

/// A selection handle (Planning.md, Draw › Selection: the outline's handles).
enum DrawHandle: Equatable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    /// A text box's sides.
    case left, right
    /// A line's or arrow's ends.
    case start, end
}

/// A handle where the board draws it, in board points (y down).
struct DrawHandleSpot: Equatable {
    var handle: DrawHandle
    var point: CGPoint
}

extension DrawPageModel {
    /// The 6 pt handle takes presses this far from its centre.
    static let handleHitRadius: CGFloat = 8

    /// The handles of the selection, as drawn.
    var handleSpots: [DrawHandleSpot] { [] }

    /// The handle under a press, if any.
    func handleSpot(at screen: CGPoint) -> DrawHandleSpot? { nil }
}
