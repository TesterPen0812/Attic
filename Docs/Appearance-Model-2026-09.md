# Appearance model — September 2026

This is the source-of-truth ledger for Attic's current local-first macOS appearance model. It records what each setting owns, how translucent surfaces stay readable, how Tint is calibrated, and how the unreleased appearance migration behaves.

## 1. User-facing model

| control | values | persisted key | owns |
|---|---|---|---|
| Palette | Original + six custom palettes | `panelTheme` | accent, opaque surface, tint hue, edge |
| Surface | Solid / Glass / Frosted | `panelSurfaceStyle` | base surface implementation |
| Tint | Off / Subtle / Vivid / Bold | `panelTint` | calibrated accent wash at the top |
| Mode | System / Light / Dark | `appearancePreference` | effective appearance |

`AtticPanelTheme.surfaceTreatment(...)` is the single settings-to-rendering resolver. The main panel, subtask panel and Settings preview use the same `AtticPanelSurfaceTreatment` model.

The in-shape order is:

**surface → readable foundation (translucent surfaces only) → Tint wash → hairline edge**

The outside-only elevation remains outside the clip. Reduce Transparency resolves the surface to Solid while preserving the selected Tint step and stored Surface choice.

## 2. Surfaces and readable foundation

### 2.1 Solid

Solid is the palette's `opaqueSurface` at opacity 1. It does not transmit the desktop. Original Light remains exactly white; the edge and elevation provide its boundary.

### 2.2 Glass and Frosted

Glass uses native `.glassEffect(.regular)` on macOS 26+ and its existing material fallback below macOS 26. Frosted uses `.ultraThinMaterial` on the native-surface path and the existing fallback below macOS 26. Both put the palette's `opaqueSurface` above the native surface as a readable foundation.

The previous model solved that foundation as though raw white or black sat immediately below it. That ignored the native surface's own movement of the desktop toward a mid-tone and made Glass and Frosted much more opaque than required.

The owner brief supplied these 2× sRGB measurements from a macOS 27 SwiftUI prototype with **0% foundation**. The panel interior was averaged for each bare native surface:

| surface | appearance | over white | over black | over mid-grey 128 |
|---|---:|---:|---:|---:|
| `.glassEffect(.regular)` | Dark | 139 | 20 | 117 |
| `.glassEffect(.regular)` | Light | 236 | 104 | 173 |
| `.ultraThinMaterial` | Dark | 166 | 24 | 93 |
| `.ultraThinMaterial` | Light | 241 | 89 | 166 |

For readability, the worst desktop extreme is white for a Dark panel and black for a Light panel. `AtticPanelSurfaceTreatment.worstCaseUnderlay(kind:appearance:creditsNativeSurface:)` is the named source of truth for the resulting neutral underlay beneath the foundation:

- Glass: Dark `143/255`, Light `104/255`

Dark Glass is the one value not taken straight from the prototype table. In the
running app, over a full-screen white backdrop, Original Dark Glass at 33 %
foundation measured 102 at the top of the panel where the prototype model
predicted 99, so real Liquid Glass over the desktop transmits slightly more
than it did inside the prototype window. Solving back from that capture gives
an underlay of 143, which is what the code uses. The other three values agreed
with the running app within one level (Light Glass 139 vs 139, Dark Frosted 99
vs 98, Light Frosted 140 vs 139).
- Frosted: Dark `166/255`, Light `89/255`

These credits apply only when the native macOS 26+ surface is in use. `creditsNativeSurface` defaults to `AtticGlassControlTreatment.systemSupportsNativeGlass`, but tests pin both paths explicitly. Below macOS 26 the underlay remains the historical raw extreme: white for Dark and black for Light.

For Tint Off, `minimumReadableOpacity` solves the first whole-percent foundation whose composite keeps **both** fixed palette foregrounds at or above **4.75:1**. Solid is always 1.00.

For arbitrary desktop colours used by the contrast tests, the measured black/white native-surface endpoints are interpolated linearly per sRGB channel. The prototype gives the endpoints and a mid-grey observation; this interpolation is the explicit validation assumption for intermediate backdrops, not a claim that the system compositor is physically linear in every condition.

### 2.3 Current Tint-Off foundation

| palette | appearance | Glass | Frosted |
|---|---|---:|---:|
| Original | Light | 0.23 | 0.30 |
| Original | Dark | 0.36 | 0.46 |
| Midnight Cobalt | Light | 0.25 | 0.32 |
| Midnight Cobalt | Dark | 0.35 | 0.45 |
| Porcelain Vapor | Light | 0.24 | 0.31 |
| Porcelain Vapor | Dark | 0.39 | 0.49 |
| Smoked Umber | Light | 0.25 | 0.33 |
| Smoked Umber | Dark | 0.36 | 0.46 |
| Electric Blue | Light | 0.23 | 0.30 |
| Electric Blue | Dark | 0.36 | 0.46 |
| Sea Glass | Light | 0.24 | 0.31 |
| Sea Glass | Dark | 0.37 | 0.48 |
| Amethyst | Light | 0.24 | 0.32 |
| Amethyst | Dark | 0.37 | 0.47 |

The uncredited fallback deliberately reproduces the previous whole-percent foundations exactly: Original 0.54/0.66 (Light/Dark), Midnight Cobalt 0.57/0.66, Porcelain Vapor 0.56/0.69, Smoked Umber 0.58/0.67, Electric Blue 0.55/0.66, Sea Glass 0.57/0.68, and Amethyst 0.57/0.67. The same fallback foundation applies to Glass and Frosted because the old model did not credit either material.

## 3. Removed: Depth

The neutral black/white crown was removed from every surface and setting. The owner's reason is that it did not add a distinct useful dimension: on Original it was effectively another tint, while on the other palettes it complicated the surface model and had been masking Tint's lack of contrast headroom. The current model gives Tint the necessary headroom through its calibrated foundation instead.

## 4. Tint calibration

Tint is a saturated version of the palette accent hue. It fades linearly from its calibrated top opacity to zero at 60% of the panel height. The three non-off steps target CIE Lab ΔE76 values of **3 / 7 / 12** for Subtle / Vivid / Bold.

The generated calibration has **7 palettes × 2 appearances × 3 surface kinds × 3 non-off steps = 126 cells**. There is no additional axis. Each cell stores:

- `foundationOpacity`
- `topOpacity`
- the resulting ΔE76
- a clamp flag retained only as a defensive fallback

For Glass and Frosted, calibration begins at the Tint-Off foundation. For each whole-percent foundation `f` from there through 1.00, the solver finds the wash opacity `α` that reaches the step's ΔE target over the base composite at `f`. It accepts the first `f` whose top-edge tinted composite keeps primary and secondary foreground contrast at or above 4.75:1. This makes the foundation monotone non-decreasing as Tint gets stronger and lets the wash reach its intended colour difference instead of being forced almost invisible.

Solid keeps foundation 1.00 and its existing Tint behaviour. On the native-credited path nothing solves at draw time: `PanelTintCalibration.table` supplies both values. On the uncredited fallback path the same cell solver runs once when the treatment is initialized over the raw white/black extreme, and that treatment stores both its solved foundation and its solved top opacity.

The generated table currently contains **zero clamped cells**. The presentation helper retains neutral fallback wording for a future pathological palette, but Settings shows no clamp footer for the current table. Tests independently convert sRGB to Lab, require every cell to land within ±0.25 ΔE of its target, require zero clamps, and require the tint-aware foundation to be monotone non-decreasing by step.

The eight-desktop-extremes readability check transforms each RGB extreme through the measured native-surface endpoint model, samples the wash fade at multiple vertical positions, and requires at least 4.5:1 at every location. The stricter generation boundary remains 4.75:1 at the calibrated worst-case top edge.

## 5. Appearance migration

This branch is unreleased, so `appearanceSchemaVersion` remains **2**. The migration maps the retired translucency / glass-style / gradient preferences directly into Surface and Tint:

| retired state | current result |
|---|---|
| no stored appearance key at all (fresh install) | Surface Glass, Tint Off |
| `isTranslucent == false` | Solid |
| `panelGlassStyle == frosted` | Glass |
| `panelGlassStyle == stable` or `liveStable` | Frosted |
| `panelGlassStyle == clear`, unknown, or missing old default | Glass |

Tint migration is unchanged: coverage 0 maps to Off; otherwise the old gradient's visible Light-mode colour difference is measured on the same ΔE76 scale and mapped to the closest product step thresholds already defined by `PanelTintLevel`.

Preview builds of this unreleased branch may have written the retired crown preference. `AppearanceMigration.migrateIfNeeded` therefore removes that stale key **unconditionally before the schema-version guard**, including stores already at version 2. Repeating the migration remains idempotent and does not rewrite current Surface or Tint choices.

## 6. Shared rendering and accessibility

The main panel, subtask checklist and Settings preview all resolve through the same treatment. Increased Contrast changes edge/selection presentation but not the palette values that the foundation/Tint calibration depends on. Reduce Transparency forces the drawable kind to Solid without changing the persisted Surface choice.

Native-glass control treatment remains separate from the panel surface selection. Interactive controls use the existing native Liquid Glass path when supported, material fallback on older systems, and the opaque accessibility treatment when Reduce Transparency is enabled.

## 7. Readable foundation: old versus current model

The old conservative solver used the raw desktop extreme below every translucent surface. Across the palettes that produced roughly 54–58% foundations in Light and 66–69% in Dark. The measured native-surface model credits the tone already supplied by the system surface, reducing Tint-Off Glass to 23–39% and Frosted to 30–49% across the current palettes.

Tint may deliberately raise that foundation just enough to preserve text while reaching its colour target. At Bold, Glass ranges from 24% to 50% and Frosted from 31% to 59% depending on palette and appearance. The result keeps more of the native surface visible at Tint Off, then spends opacity only when a stronger Tint step needs contrast headroom.
