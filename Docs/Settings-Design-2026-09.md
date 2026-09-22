# Attic Settings redesign (September 2026)

The Settings window was rebuilt around one idea: it should feel like a
first-party macOS 26 app with Attic's point of view, not a web form. Every
pane (General, Panel, Appearance, Agent Access, About), the sidebar and the
shared components were redone; every behaviour and every accessibility
identifier that tests rely on was kept. Screenshots are in
`Docs/Settings-Design-2026-09/` (`settings-before-*` from `main` at 5451490,
`settings-after-*` from this branch, Light and Dark, 860 × 550 pt; the
`-tall` pair is the Appearance pane at 640 × 900 pt).

## 1. Principles

1. **Native first.** Each pane is a grouped `Form` (`.formStyle(.grouped)`),
   which is how System Settings on Tahoe draws a pane: inset rounded groups,
   vibrant separators, section headers in sentence case, secondary footers.
   Light, Dark, Increased Contrast, keyboard focus rings and VoiceOver row
   semantics come from the framework instead of being re-implemented.
2. **One scale.** A title block (22 pt semibold + callout subtitle) opens
   the scrolling form; rows use the system body size with caption
   descriptions; the tinted 24 pt symbol tile in front of every row is the
   System Settings idiom and the only decorative element.
3. **Show, don't describe.** Where a choice is visual it is drawn: the palette
   tiles show each palette's Light and Dark surface with its accent, the
   surface tiles show what Solid, Glass and Frosted do to a tiny desktop, the
   tint pills show the wash at the strength it really gets, the corner picker
   is a little display, and the Appearance pane opens with a live miniature of
   the real panel.
4. **Copy from the user's side.** Short, specific, active. "Attic is ready as
   soon as you sign in." "Rest the pointer in this corner of any display to
   open Attic." No "Glassmorphism", no "adaptive", no internal names.
5. **Attic's accent.** The window tint follows the panel palette, as before
   (`settingsAccentColor`), so the selected sidebar row, the selection rings
   and the segmented controls take the palette's colour.

## 2. Structure and chrome

- `NavigationSplitView` with a balanced sidebar (min 172 / ideal 196 / max
  230 pt) and the existing window sizes (preferred 860 × 650, minimum 640 ×
  460, maximum 1100 × 900; `SettingsWindowLayout` is unchanged and still
  tested).
- **Sidebar:** the app icon with "Attic / Settings" as a top inset, then one
  row per pane with a tinted symbol tile (`SettingsSection.tint`: gray, blue,
  purple, orange, teal) and the section title. Identifiers: `settings-sidebar`
  on the list, `settings-nav-<section>` on each row.
- **Pane:** `SettingsPage(title:subtitle:accessibilityIdentifier:)` is one
  grouped form whose first row is the title block, so the whole pane scrolls
  as one surface (scroll-wheel anywhere, including over the title);
  `settings-page-<section>` sits on the pane as a single accessibility
  container, as before.

## 3. Spacing and type scale

| Element | Value |
|---|---|
| Pane title | 22 pt semibold; subtitle `.callout` secondary |
| Title block insets | form gutter horizontally, 8 pt top, 2 pt bottom |
| Row title / description | body / `.caption` secondary |
| Row icon tile | 24 × 24 pt, corner 6 pt continuous, 11.5 pt semibold white symbol on `tint.gradient` |
| Section header / footer | native grouped form (headline / caption secondary) |
| Choosable tile | corner 10 pt continuous; boundary 1 pt at 0.14 (Increased Contrast 1.5 pt at 0.42); selection ring 2 pt accent (2.5 pt) |
| Palette tile | adaptive grid, 104–150 pt wide, min height 74 pt, two 40 × 30 pt squircle swatches |
| Surface tile | three equal columns; 44 pt hint, callout title, caption line |
| Tint pill | four equal columns; 34 pt sample, caption title |
| Corner picker | 116 × 74 pt display, 22 pt targets, name underneath |
| Live preview card | full width, 248 pt tall, corner 14 pt; miniature panel = real panel × 0.46 |

All of these are constants in `SettingsDesign`, `AppearancePreviewLayout`,
`AppearanceSettingsPresentation` and `CornerPicker`, pinned by
`SettingsPresentationTests`.

## 4. Component inventory (`Attic/Views/Settings/`)

| Component | File | Role |
|---|---|---|
| `SettingsPage` | SettingsComponents.swift | title block + grouped `Form`, one scrolling surface |
| `SettingsRow` / `SettingsRowLabel` | SettingsComponents.swift | `LabeledContent` row with icon tile, title, description, trailing control |
| `SettingsIcon` | SettingsComponents.swift | the tinted symbol tile |
| `SettingsMessage` | SettingsComponents.swift | information / warning / error line inside a section |
| `SettingsFootnote` | SettingsComponents.swift | section footer text |
| `settingsTileSelection` | SettingsComponents.swift | the ring and boundary shared by every choosable tile |
| `SettingsSection` | SettingsSection.swift | sections, symbols, tints, identifiers |
| `SettingsSidebar` | SettingsView.swift | identity header + tinted rows |
| `CornerPicker` | CornerPicker.swift | the little display with four corner targets |
| `PaletteChooser` | AppearanceChoosers.swift | palette tiles |
| `SurfaceChooser` | AppearanceChoosers.swift | Solid · Glass · Frosted tiles |
| `TintChooser` | AppearanceChoosers.swift | Off · Subtle · Vivid · Bold pills |
| `AppearancePreviewCard` | AppearancePreview.swift | the live miniature over a representative backdrop |

Removed: `SettingsGroup` (a hand-drawn group box) and `SettingsDivider`; the
native form draws both.

## 5. The panes

### General
Startup section: "Launch at login" (toggle, `setting-launch-at-login`); when
macOS wants approval, an "Approval needed" row with **Open Login Items**
(`settings-login-approval`, `settings-open-login-items`); the login error as a
message row (`settings-login-error`). Footer: where Attic lives. The Shortcut
section appears only when the global shortcut was refused
(`settings-global-shortcut-unavailable`), as before.

### Panel
Corner: "Reveal from" with the display-shaped `CornerPicker`
(`setting-hiding-corner`, `setting-corner-<corner>`); footer carries the
drag-to-corner, swipe-to-hide and Hot Corners notes, rewritten. Timing: reveal
and hide delay sliders with readouts (`setting-reveal-delay`,
`setting-hide-delay`). Shape: corner size and width (`setting-panel-corner-size`,
`setting-panel-width`); footer explains the anchored corner.

### Appearance
1. The live preview (`setting-appearance-preview`): `AppearancePreviewCard`
   renders `AtticPanelSurface` with the exact treatment the panel would use
   (`AppSettings.panelSurfaceTreatment`), at 0.46 scale, with real
   native-glass controls (`atticGlassControl`), `TaskStatusMark` rows and the
   outside-only shadow, over a small desktop with colour and a window of text
   so Glass and Frosted show what they transmit. It lives in the effective
   appearance (a Dark panel previews as Dark inside a Light window), obeys
   Reduce Transparency and Increased Contrast through the same environment
   the panel reads, and its crossfade obeys Reduce Motion because the modifier
   does. VoiceOver reads one element: "Panel preview: Sea Glass palette, Glass
   surface, Depth on, Tint Vivid, Dark appearance."
2. Mode: System · Light · Dark (`setting-appearance`).
3. Palette: tiles (`setting-panel-theme`, `setting-panel-theme-<theme>`).
4. Surface: three tiles (`setting-panel-surface`, `setting-panel-surface-<style>`,
   each labelled Solid / Glass / Frosted with a selected trait); Depth toggle
   (`setting-panel-depth`); Tint pills (`setting-panel-tint`,
   `setting-panel-tint-<level>`). The section footer states when the
   readability floor keeps the chosen tint faint (see
   `Docs/Appearance-Model-2026-09.md` §4.2).

Nothing else: no sliders, no colour pickers.

### Agent Access
Access: the toggle (`setting-agent-access`) and, while off, "Agent Access is
off. Nothing is listening." (`settings-agent-disabled-message`). While on:
Local server (status row, `settings-agent-server-status`, with **Retry** on
failure, `settings-agent-retry`); Connection: the endpoint with a Copy button
(`settings-agent-connection`, `settings-agent-endpoint`,
`settings-copy-agent-endpoint`) and Authorization with "Kept private and never
shown in Settings." (`settings-agent-authorization-summary`), **Copy Setup
Prompt** (`settings-copy-agent-setup`) and "Ready to paste"
(`settings-agent-setup-copied`). The token is never displayed; the footer
says what the clipboard holds.

### About
The icon with name, version (`settings-app-version`) and "Local-first on this
Mac"; Source with **Open Repository** (`settings-open-repository`).

## 6. Accessibility

- Every identifier listed in the brief is on an element with the same role
  (rows for rows, buttons for buttons, the page container for pages).
- Every custom tile is a `Button` with a label, a value ("Selected"), a hint
  and the selected trait; the chooser containers carry a label and the
  current value.
- Increased Contrast: tile boundaries 0.42 / 1.5 pt, selection rings 2.5 pt,
  the preview card border 0.28; the native form strengthens the rest.
- Reduce Transparency: the preview draws Solid and the Appearance footer says
  so; the Surface choice is kept.
- Keyboard: native form rows, toggles, segmented pickers and plain buttons
  keep focus rings; tab order follows the form.

## 7. Before and after

| Pane | Before | After |
|---|---|---|
| General | `settings-before-general-light.jpg` / `-dark` | `settings-after-general-light.jpg` / `-dark` |
| Panel | `settings-before-panel-light.jpg` / `-dark` | `settings-after-panel-light.jpg` / `-dark` |
| Appearance | `settings-before-appearance-light.jpg` / `-dark`, `-tall-*` | `settings-after-appearance-light.jpg` / `-dark`, `-tall-*` |
| Agent Access | `settings-before-agentAccess-light.jpg` / `-dark` | `settings-after-agentAccess-light.jpg` / `-dark` |
| About | `settings-before-about-light.jpg` / `-dark` | `settings-after-about-light.jpg` / `-dark` |

What changed at a glance: hand-drawn group boxes with uppercase tracked
headers became native grouped sections; grey circle glyphs became tinted
symbol tiles; the translucency toggle, glass picker, gradient slider and
colour picker became the live preview, palette tiles, surface tiles, a Depth
toggle and tint pills; the corner picker became a display; every footer
explains one thing in one sentence.
