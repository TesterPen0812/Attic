import Foundation

/// A decoded view of supported bytes. Callers retain the original payload,
/// including unknown fields, until an explicit supported edit replaces it.
struct CanvasCoreSemanticContract: Codable, Equatable {
    struct Point: Codable, Equatable { let x: Double; let y: Double }
    enum Size: String, Codable, CaseIterable { case small, medium, large
        var points: Double { switch self { case .small: 18; case .medium: 24; case .large: 32 } }
    }
    static let cornerRadius = 8.0
    var text: String?
    var shape: String?
    var color: String
    var strokeWidth: Double
    var fontSize: Double?
    var fontWeight: String?
    var alignment: String?
    var wrapWidth: Double?
    var size: Size?
    var rounded: Bool?
    var start: Point?
    var end: Point?
    var resolvedFontSize: Double { size?.points ?? fontSize ?? 24 }
    var resolvedCornerRadius: Double { shape == "rectangle" && rounded == true ? Self.cornerRadius : 0 }
    func validate() throws {
        guard CanvasCoreInkCodec.colors.contains(color), strokeWidth.isFinite, strokeWidth > 0, strokeWidth <= 16,
              resolvedFontSize.isFinite, (8...144).contains(resolvedFontSize),
              wrapWidth.map({ $0.isFinite && $0 >= 1 && $0 <= 100_000 }) ?? true,
              (fontWeight.map { ["regular", "semibold", "bold"].contains($0) } ?? true),
              (alignment.map { ["left", "center", "right"].contains($0) } ?? true),
              (text != nil) != (shape != nil),
              text.map({ !$0.isEmpty && $0.utf8.count <= 65_536 }) ?? true,
              shape.map({ ["rectangle", "ellipse", "line", "arrow"].contains($0) }) ?? true,
              [start, end].compactMap { $0 }.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              rounded == nil || shape == "rectangle" else { throw CanvasCoreError.invalidPayload }
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= 6 * 65_536 + 4_096 else { throw CanvasCoreError.admission }
        let value = try JSONDecoder().decode(Self.self, from: bytes); try value.validate(); return value
    }
    func encode() throws -> Data { try validate(); return try JSONEncoder().encode(self) }
}
