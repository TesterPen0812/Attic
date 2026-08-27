import Foundation

// CanvasPoint is an immutable value type containing only Sendable Doubles.
// Keep the conformance in this shared file so both targets use the same model,
// while avoiding a Swift 6 warning about a retroactive checked conformance.
extension CanvasPoint: @unchecked Sendable {}
