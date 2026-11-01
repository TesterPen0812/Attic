import SwiftUI

// MARK: - Scroll edges before controls (D1, 2026-10-02; Clean cut, 2026-10-03)

/// Tasks and Done use Clean cut.
/// The owner disabled the native soft edge everywhere (overnight A1,
/// 2026-10-04), including saved preview choices and environment overrides.
/// Former soft-edge choices also resolve to Clean cut. Notes editor,
/// All notes and E1 cards use clean edges too.
extension View {
    /// Native effects stay hidden, including legacy geometry test injection.
    func atticScrollEdgeEffect() -> some View {
        scrollEdgeEffectHidden(true, for: .all)
    }
}
