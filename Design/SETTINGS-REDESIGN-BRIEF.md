# Attic Settings Redesign Reference

`SettingsPremiumReference.png` is a visual direction, not a pixel-for-pixel mandate.

Preserve every existing setting, binding, error state, accessibility label, secret-handling rule, and CloudKit/MCP behavior. Improve hierarchy and native macOS usability without turning the window into an iOS form or web dashboard.

Key direction:

- Native macOS sidebar with General, Panel, Appearance, Sync, Agent Access, and About.
- Calm two-column layout with compact grouped sections and predictable alignment.
- A small, truthful live panel preview where useful; never fake behavior.
- Restrained Liquid Glass in chrome/sidebar only; content must remain highly legible.
- Excellent Light, Dark, keyboard, VoiceOver, Dynamic Type, narrow-window, and scrolling behavior.
- No decorative controls, oversized cards, clipped text, or hidden functionality.

The implementation must be judged in the running app. Source inspection, snapshots, builds, and unit tests do not substitute for visual and interaction UAT.
