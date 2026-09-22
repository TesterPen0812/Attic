# Appearance model — September 2026

This is the source-of-truth ledger for Attic's current local-first macOS appearance model. It records what each setting owns, how translucent surfaces stay readable, how Tint is calibrated, and how the unreleased appearance migration behaves.

## 1. User-facing model

| control | values | persisted key | owns |
|---|---|---|---|
| Palette | Original + six custom palettes | `panelTheme` | accent, opaque surface, tint hue, edge |
| Surface | Solid / Glass / Frosted | `panelSurfaceStyle` | base surface implementation |
| Tint | Off / Subtle / Vivid / Bold | `panelTint` | Original: neutral shade; custom palettes: calibrated accent wash |
| Tint length | 30–100% of the panel height, default 100% | `panelTintLength` | how far down the Tint reaches (§4.3) |
| Mode | System / Light / Dark | `appearancePreference` | effective appearance |

`AtticPanelTheme.surfaceTreatment(...)` is the single settings-to-rendering resolver. The main panel, subtask panel and Settings preview use the same `AtticPanelSurfaceTreatment` model.

The in-shape order is:

**surface → readable foundation (translucent surfaces only) → Tint → hairline edge**

One exception: Original with a Tint step on native Glass or Frosted has no flat foundation; the neutral shade is the readability layer (§4.1). The outside-only elevation remains outside the clip. Reduce Transparency resolves the surface to Solid while preserving the selected Tint step, Tint length and stored Surface choice.

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

The Light rows matter for Dark panels too: Original's shaded Glass and Frosted draw the native surface in its Light appearance (§4.1). Drawn that way inside a running Dark panel, Light `.glassEffect(.regular)` passed a white page almost untouched, **254** rather than the prototype's 236; Light `.ultraThinMaterial` matched the prototype's 241.

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

For Tint Off, `minimumReadableOpacity` solves the first whole-percent foundation whose composite keeps **both** fixed palette foregrounds at or above the surface's floor, `readableContrastTarget(kind:creditsNativeSurface:)`. Solid is always 1.00.

| surface | worst-case floor | why |
|---|---:|---|
| Glass (macOS 26+) | **3.0:1** | the owner asked for Siri-level transparency; the Siri panel's lower third measures about 2.4–3:1 for white text over a white page (captured on macOS 27, September 2026) |
| Frosted (macOS 26+) | **3.5:1** | the calmer, easier-to-read translucent choice, always more opaque than Glass |
| Solid, and every surface below macOS 26 | 4.75:1 | the historical floor, a small buffer above WCAG AA 4.5:1 |

The floors are for the worst case only: a pure white page behind a Dark panel, pure black behind a Light one. Over a typical desktop the native surface transmits mid-tones and the text reads far better. This is a deliberate trade: small text in the lower half of a Dark Glass panel over a bright white page is about as readable as Siri's, below WCAG AA. In the running app the floors measured exactly: Original Dark Glass 3.0:1 and Frosted 3.6:1 over white, Original Light Glass 3.0–3.1:1 and Frosted 3.6:1 over black; with Original's neutral Tint on Glass or Frosted the floor instead relaxes down the panel, to about 2.1:1 at the bottom of Dark Glass (§4.1).

A second consequence: Light Glass carries about 1% foundation and Light Frosted about 17%, and the custom palettes' Light surfaces are all near-white, so in Light on those surfaces the palettes are no longer told apart by their fill. Their accent, edge and Tint still differ (`testPanelThemeIdentityIsQuantizedDistinctInEveryVisibleSurfaceState`); the fill-only distinctness test now covers Solid and every Dark surface.

For arbitrary desktop colours used by the contrast tests, the measured black/white native-surface endpoints are interpolated linearly per sRGB channel. The prototype gives the endpoints and a mid-grey observation; this interpolation is the explicit validation assumption for intermediate backdrops, not a claim that the system compositor is physically linear in every condition.

### 2.3 Current Tint-Off foundation (Glass at 3.0:1, Frosted at 3.5:1)

| palette | appearance | Glass | Frosted |
|---|---|---:|---:|
| Original | Light | 0.01 | 0.16 |
| Original | Dark | 0.10 | 0.32 |
| Midnight Cobalt | Light | 0.01 | 0.18 |
| Midnight Cobalt | Dark | 0.10 | 0.31 |
| Porcelain Vapor | Light | 0.01 | 0.17 |
| Porcelain Vapor | Dark | 0.11 | 0.34 |
| Smoked Umber | Light | 0.01 | 0.18 |
| Smoked Umber | Dark | 0.10 | 0.32 |
| Electric Blue | Light | 0.01 | 0.17 |
| Electric Blue | Dark | 0.10 | 0.31 |
| Sea Glass | Light | 0.01 | 0.17 |
| Sea Glass | Dark | 0.10 | 0.33 |
| Amethyst | Light | 0.01 | 0.17 |
| Amethyst | Dark | 0.10 | 0.32 |

The uncredited fallback deliberately reproduces the previous whole-percent foundations exactly: Original 0.54/0.66 (Light/Dark), Midnight Cobalt 0.57/0.66, Porcelain Vapor 0.56/0.69, Smoked Umber 0.58/0.67, Electric Blue 0.55/0.66, Sea Glass 0.57/0.68, and Amethyst 0.57/0.67. The same fallback foundation applies to Glass and Frosted because the old model did not credit either material.

## 3. Removed: Depth

The Depth toggle (a neutral black/white crown over any surface) was removed. The owner's reasons: the dark-mode and Depth combination was messy, on Original Depth was effectively another tint, and they preferred it off in every mode; over the heavy foundation of the time it also did not read like the Siri-style panel it came from. The crown lives on as **Original's Tint** (§4.1), now reshaped to the Siri panel's near-linear ramp and, on Glass and Frosted, carrying readability itself.

## 4. Tint

Tint is one layer across the top of the panel, in one of two forms. Both are drawn from `AtticPanelSurfaceTreatment.tintStops`, which the readability model interpolates too, so what is tested is what is drawn.

### 4.1 Original: the neutral shade

Original is Attic's neutral palette, so its Tint has no colour: it is black in Dark and white in Light (`PanelNeutralShade`). Original's coloured (blue) wash from the previous model is gone.

**What it is matched to.** The owner found the first version (the old Clear crown over the Tint-Off foundation) still barely see-through next to the macOS 27 Siri panel. Over a white page Siri's panel brightness (0 = black, 255 = white) runs almost linearly: about 5 at the top, 50 at a quarter, 100 at mid-height, 145 at three quarters and 175–180 at the bottom, where white text is only about 1.9:1. Attic's Bold ran 27 → 67 → 121 and stayed dark lower down, for two reasons: `.regular` Liquid Glass in its Dark appearance greys a white page to about 143 before anything is added, and the Tint-Off foundation and a crown that faded early added more. A prototype showed that the same glass in its **Light** appearance plus a straight black ramp reproduces Siri (15 / 48 / 101 / 145 / 170).

**Construction on native Glass and Frosted** (`AtticPanelSurfaceTreatment.usesShadeAsFoundation`: Original, a Tint step, Glass or Frosted, macOS 26+):

- The native surface is drawn in its Light appearance in both modes (`AtticPanelSurface.nativeSurfaceColorScheme`), so the desktop keeps its own brightness and all the darkening comes from the shade. Controls and content keep the panel's appearance.
- There is no flat foundation (0%). The shade is the readability layer.
- The profile is fitted to Siri: opacity 0.98 at the top, 0.80 at 25%, 0.57 at 50%, 0.38 at 75% and 0.25 at the bottom. Subtle, Vivid and Bold scale the opacities by 0.35, 0.65 and 1.00; Tint length scales the locations, and below the length the ramp holds its last value.
- A readability floor relaxes linearly with height (`PanelNeutralShade.readableFloor`): 4.75:1 at the top edge down to **2.0:1** at the bottom on Glass (Siri's lower edge) and **2.5:1** on Frosted.
- At every 5% of the height (`sampleCount = 21` gradient stops), the drawn opacity is the larger of the step's ramp and the least shade that keeps both foregrounds at the floor over the worst-case bright surface (`brightUnderlay`: a white page seen through bright Glass 254 or bright Frosted 241 behind a Dark panel; a black page seen through them, 104 and 89, behind a Light one), rounded up to thousandths (`readableStops`).

So Bold is the Siri ramp wherever it is already readable. Subtle and Vivid are lighter at the top and follow the floor lower down. The floor never clamps and there is no calibration table.

**Unchanged.** Tint Off keeps the flat Tint-Off foundation (Glass 3.0:1, Frosted 3.5:1, §2) with the surface in the panel's own appearance. On Solid, under Reduce Transparency (which draws Solid), and on every surface below macOS 26, the shade is drawn over the usual foundation with the profile above. There it can only raise contrast: it moves the surface toward black under white text (Dark) and toward white under dark text (Light). The custom palettes' accent wash (§4.2) is untouched.

**The trade-off, stated plainly.** Over a pure white page, the lower rows of a Dark Glass panel with Original's Tint read at about 2:1, like Siri's, where Tint Off keeps 3:1. The top stays at 4.75:1 or better. Frosted keeps 2.5:1 at the bottom. Typical desktops read far better than a pure white page.

**Tests.** `testShadeCarriesReadabilityOnNativeTranslucentSurfaces` checks each stop meets its floor over the bright surface, is never darker than the ramp or floor asks for, and is monotone by step. `testShadeKeepsItsFloorOverEveryDesktopExtreme` checks the floor at every 5% over all eight desktop extremes through the bright surface's measured endpoints. `testBoldGlassFollowsTheSiriRamp` pins Bold over a white page to the Siri numbers. `testShadeOverTheUsualSurfaceNeverLowersContrast` covers Solid and the pre-macOS 26 path.

**Measured in the running app** (September 2026, macOS 27, full-screen white page behind Dark and black page behind Light, brightness averaged in the empty interior at 3 / 25 / 50 / 75 / 97% of the panel height, contrast against the secondary foreground 230 in Dark and 31 in Light):

| configuration | 3% | 25% | 50% | 75% | 97% |
|---|---:|---:|---:|---:|---:|
| Siri panel, for reference | ~5 | ~50 | ~100 | ~145 | ~175–180 (1.9:1) |
| Dark Glass Bold | 11 (15.8:1) | 51 (10.1:1) | 110 (4.1:1) | 139 (2.7:1) | 158 (2.1:1) |
| Dark Glass Vivid | 95 (5.1:1) | 110 (4.1:1) | 124 (3.4:1) | 139 (2.7:1) | 158 (2.1:1) |
| Dark Glass Subtle | 99 (4.8:1) | 110 (4.1:1) | 124 (3.4:1) | 139 (2.7:1) | 158 (2.1:1) |
| Dark Glass Bold, length 50% | 16 (15.2:1) | 109 (4.2:1) | 124 (3.4:1) | 139 (2.7:1) | 158 (2.1:1) |
| Dark Frosted Bold | 10 (15.9:1) | 48 (10.6:1) | 104 (4.5:1) | 130 (3.1:1) | 142 (2.6:1) |
| Dark Glass Tint Off | 131 (3.0:1) | 132 (3.0:1) | 132 (3.0:1) | 132 (3.0:1) | 132 (3.0:1) |
| Light Glass Bold (over black) | 249 (15.6:1) | 225 (12.6:1) | 191 (8.9:1) | 163 (6.5:1) | 144 (5.2:1) |

The first capture used the prototype's 236 for bright Glass and came out lighter than the model at every height (Bold's bottom at 171, 1.84:1). Solving back from it gave 254 at every sampled height, which is what `brightUnderlay` now uses. Every sample then sits on or within 0.02 of its floor, and Bold is within about 10 levels of Siri down to three quarters. Only the bottom is darker (158 against 175–180), because the 2:1 floor stops short of Siri's 1.9:1. In Dark, Subtle and Vivid differ only near the top, because the floor sets the rest.

On Original Light Solid, whose surface is exactly `#FFFFFF`, a white shade is invisible by construction.

### 4.2 Custom palettes: the calibrated accent wash

The custom palettes' Tint is a saturated version of the palette accent hue. It fades linearly from its calibrated top opacity to zero at the Tint length (§4.3). The three non-off steps target CIE Lab ΔE76 values of **3 / 7 / 12** for Subtle / Vivid / Bold.

The generated calibration has **6 palettes × 2 appearances × 3 surface kinds × 3 non-off steps = 108 cells** (Original is not in it). There is no additional axis. Each cell stores:

- `foundationOpacity`
- `topOpacity`
- the resulting ΔE76
- a clamp flag retained only as a defensive fallback

For Glass and Frosted, calibration begins at the Tint-Off foundation. For each whole-percent foundation `f` from there through 1.00, the solver finds the wash opacity `α` that reaches the step's ΔE target over the base composite at `f`. It accepts the first `f` whose top-edge tinted composite keeps primary and secondary foreground contrast at or above the surface's floor (Glass 3.0, Frosted 3.5, Solid 4.75). This makes the foundation monotone non-decreasing as Tint gets stronger and lets the wash reach its intended colour difference instead of being forced almost invisible.

Solid keeps foundation 1.00 and its existing Tint behaviour. On the native-credited path nothing solves at draw time: `PanelTintCalibration.table` supplies both values. On the uncredited fallback path the same cell solver runs once when the treatment is initialized over the raw white/black extreme, and that treatment stores both its solved foundation and its solved top opacity.

The generated table currently contains **zero clamped cells**. The presentation helper retains neutral fallback wording for a future pathological palette, but Settings shows no clamp footer for the current table. Tests independently convert sRGB to Lab, require every cell to land within ±0.25 ΔE of its target, require zero clamps, and require the tint-aware foundation to be monotone non-decreasing by step.

The eight-desktop-extremes readability check transforms each RGB extreme through the measured native-surface endpoint model, samples the wash fade at multiple vertical positions for Tint lengths 30%, 60% and 100%, and requires the surface's floor at every location: the wash only fades from the top edge, where it is calibrated.

### 4.3 Tint length

One slider under the Tint steps (`setting-panel-tint-length`, 30–100%, default 100%) sets how far down either Tint reaches. For the accent wash it is where the linear fade reaches zero; for the neutral shade it scales the profile's stop locations. It is disabled while Tint is Off. Readability does not depend on it. For the accent wash, the Tint's opacity at every height is at most its top-edge opacity, and the calibration is judged at the top edge, so a longer Tint never needs more foundation. For Original's shade on Glass and Frosted the floor is enforced at every height whatever the length, so a short shade leaves the floor to carry the lower panel. It replaces the retired gradient coverage slider, and the migration carries an old coverage into it (§5).

## 5. Appearance migration

This branch is unreleased, so `appearanceSchemaVersion` remains **2**. The migration maps the retired translucency / glass-style / gradient preferences directly into Surface and Tint:

| retired state | current result |
|---|---|
| no stored appearance key at all (fresh install) | Surface Glass, Tint Off |
| `isTranslucent == false` | Solid |
| `panelGlassStyle == frosted` | Glass |
| `panelGlassStyle == stable` or `liveStable` | Frosted |
| `panelGlassStyle == clear`, unknown, or missing old default | Glass |

Tint and Tint length:

| retired state | current result |
|---|---|
| Original, `panelGlassStyle == clear`, missing or an unknown spelling, and translucent | neutral Tint **Bold**, length 100% (the nearest step to the old Clear crown) |
| Original otherwise, coverage > 0 (missing = old default 0.55) | neutral Tint **Bold**, length = coverage (the old gradient was that same neutral pole at 0.82) |
| Original otherwise, coverage 0 | Tint Off |
| custom palette, coverage 0 | Tint Off |
| custom palette, coverage > 0 | the step matching the old gradient's Light-mode ΔE76 (thresholds in `PanelTintLevel`), length = coverage |

A stored custom gradient colour on Original was only mixed 12% into the neutral pole, so it also maps to the neutral shade. Coverage is clamped to the slider's 30–100%. Preview installs of this branch are already at version 2 and are not migrated again: an Original user who had picked a (blue) Tint step now sees the neutral shade at that step, at the default full length. This is a change from the previous mapping, which measured Original's gradient over its opaque Light surface (white on white, ΔE ≈ 0) and so put almost every Original user on Tint Off, although in Dark and on translucent surfaces they saw a clear neutral shade.

Preview builds of this unreleased branch may have written the retired crown preference. `AppearanceMigration.migrateIfNeeded` therefore removes that stale key **unconditionally before the schema-version guard**, including stores already at version 2. Repeating the migration remains idempotent and does not rewrite current Surface or Tint choices.

## 6. Shared rendering and accessibility

The main panel, subtask checklist and Settings preview all resolve through the same treatment. Increased Contrast changes edge/selection presentation but not the palette values that the foundation/Tint calibration depends on. Reduce Transparency forces the drawable kind to Solid without changing the persisted Surface choice; Original's shade then takes the Solid path, drawn over the opaque surface (§4.1).

Native-glass control treatment remains separate from the panel surface selection. Interactive controls use the existing native Liquid Glass path when supported, material fallback on older systems, and the opaque accessibility treatment when Reduce Transparency is enabled.

## 7. Readable foundation: old versus current model

The old conservative solver used the raw desktop extreme below every translucent surface. Across the palettes that produced roughly 54–58% foundations in Light and 66–69% in Dark. The measured native-surface model credits the tone already supplied by the system surface, and the per-surface floors (Glass 3.0, Frosted 3.5) reduce Tint-Off Glass to 1% in Light and 10–11% in Dark, and Frosted to 16–18% in Light and 31–34% in Dark.

The accent wash may deliberately raise that foundation just enough to preserve text while reaching its colour target. Original's neutral shade never raises it. On Glass and Frosted it replaces the foundation (0%) and carries readability itself (§4.1). At Bold, Glass ranges from 1% to 20% and Frosted from 17% to 42% depending on palette and appearance. The result keeps more of the native surface visible at Tint Off, then spends opacity only when a stronger Tint step needs contrast headroom.
