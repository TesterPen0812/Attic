import Foundation

/// Render-cost experiments, compiled into the isolated Local preview only.
/// Every flag defaults to false; the shipping configurations contain no switches.
enum RenderLabFlags {
    #if ATTIC_RENDER_LAB
    private static let enabled: Set<String> = {
        let names = [
            "CALENDAR_MASK", "TAG_MASK", "MENU_MASK", "PANEL_CLIP", "ISLAND_MASK",
            "PANEL_SHADOW", "CONTROL_SHADOW", "ISLAND_SHADOW", "PAGE_MOTION",
            "TOP_ROW_DELAY", "BOTTOM_ROW_DELAY", "ISLAND_LABEL_DELAY",
            "ISLAND_SETTLE_DELAY", "TAG_LAYOUT", "COMPOSER_CLIP"
        ]
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.taha.Attic.preview.renderlab" else { return [] }
        if environment["ATTIC_LAB_ALL_OFF"] == "1" { return Set(names) }
        return Set(names.filter { environment["ATTIC_LAB_NO_\($0)"] == "1" })
    }()

    private static func off(_ name: String) -> Bool { enabled.contains(name) }
    #else
    private static func off(_ name: String) -> Bool { false }
    #endif

    static var noCalendarMask: Bool { off("CALENDAR_MASK") }
    static var noTagMask: Bool { off("TAG_MASK") }
    static var noMenuMask: Bool { off("MENU_MASK") }
    static var noPanelClip: Bool { off("PANEL_CLIP") }
    static var noIslandMask: Bool { off("ISLAND_MASK") }
    static var noPanelShadow: Bool { off("PANEL_SHADOW") }
    static var noControlShadow: Bool { off("CONTROL_SHADOW") }
    static var noIslandShadow: Bool { off("ISLAND_SHADOW") }
    static var noPageMotion: Bool { off("PAGE_MOTION") }
    static var noTopRowDelay: Bool { off("TOP_ROW_DELAY") }
    static var noBottomRowDelay: Bool { off("BOTTOM_ROW_DELAY") }
    static var noIslandLabelDelay: Bool { off("ISLAND_LABEL_DELAY") }
    static var noIslandSettleDelay: Bool { off("ISLAND_SETTLE_DELAY") }
    static var noTagLayout: Bool { off("TAG_LAYOUT") }
    static var noComposerClip: Bool { off("COMPOSER_CLIP") }
}
