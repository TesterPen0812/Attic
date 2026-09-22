# Attic appearance model (September 2026)

This is the record of the appearance simplification: what the user can set,
how each setting renders, how the old preferences were migrated, and how the
Tint steps were calibrated. Every number here is pinned by a unit test named
in the relevant section.

## 1. The model

| Control | Options | Stored key | Notes |
|---|---|---|---|
| Mode | System · Light · Dark | `appearancePreference` | unchanged |
| Palette | Original, Midnight Cobalt, Porcelain Vapor, Smoked Umber, Electric Blue, Sea Glass, Amethyst | `panelTheme` | unchanged palettes; Original Light Solid is exactly `#FFFFFF` |
| Surface | Solid · Glass · Frosted | `panelSurfaceStyle` (`solid` · `glass` · `frosted`) | see §2 |
| Depth | on / off | `panelDepth` (Bool) | the neutral crown, §3 |
| Tint | Off · Subtle · Vivid · Bold | `panelTint` (`off` · `subtle` · `vivid` · `bold`) | the accent wash, §4 |
| | | `appearanceSchemaVersion` = 2 | migration marker, §5 |

Removed entirely: the translucent toggle (`isTranslucent`), the glass-style
picker and its Clear option (`panelGlassStyle`), the gradient coverage slider
(`panelGradientCoverage`) and the custom gradient colour
(`panelGradientColorHex`), the 12%-pole gradient itself, and the Clear-only
"foreground readability" enable rule. The keys are deleted by the migration.

Types: `PanelSurfaceStyle`, `PanelTintLevel` (`Attic/Services/PanelAppearance.swift`),
`PanelDepthCrown` (`Attic/Design/PanelDepth.swift`), `PanelTintCalibration`
(`Attic/Design/PanelTintCalibration.swift`), `AppearanceMigration`
(`Attic/Services/AppearanceMigration.swift`). The drawable result is one
`AtticPanelSurfaceTreatment` (`Attic/Design/AtticPanelTheme.swift`) built by
`AtticPanelTheme.surfaceTreatment(appearance:contrast:surface:depth:tint:reduceTransparency:)`.

## 2. Surfaces

| Surface | Rendering (`AtticPanelSurface`, `Attic/Design/AtticStyle.swift`) | Was |
|---|---|---|
| Solid | the palette `opaqueSurface`, fully opaque | `.opaque` |
| Glass | native Liquid Glass `.regular` under the calibrated foundation | "Frosted" (`.frostedGlass`) |
| Frosted | `ultraThinMaterial` + the palette `surfaceTint` at `frostedTintOpacity`, under the same foundation | "Glassmorphism" (`.glassmorphism`) |

The foundation is the palette `opaqueSurface` at the lowest whole percent that
keeps primary **and** secondary text at ≥ 4.75:1 over a worst-case backdrop
(black behind Light, white behind Dark). Unchanged from before:
`testReadableFoundationIsTheLowestWholePercentMeetingContrastTarget`.

Layer order inside the squircle clip: surface → foundation (not Solid) →
Depth crown → Tint wash → hairline edge. Outside the clip: the outside-only
elevation. `AtticPanelSurfaceTreatment.compositedSurface(over:location:)` is
the arithmetic model of the same stack and is what every calibration and
readability test computes against.

### 2.1 The frame (identical on every surface and every panel window)

- **Edge:** one hairline per palette family. Original strokes `Color.primary`
  at 0.09; custom palettes stroke their `edgeTint` at 0.19. Increased Contrast
  adds 0.10 / 0.14. Line width 0.75 pt (1 pt in Increased Contrast). The old
  per-surface values (0.055 … 0.22) and the `isElevated` special case are
  gone. `testSurfaceEdgeIsOneHairlinePerPaletteFamilyOnEverySurface`.
- **Outer shadow:** `AtticPanelSurfaceElevation.light` 0.10 / radius 10 / y 1,
  `.dark` 0.30 / 10 / 1, on **all** surfaces, drawn by
  `AtticPanelOutsideShadow`: a shadow of the squircle with the squircle cut
  back out (`compositingGroup` + `destinationOut`), so a translucent interior
  is never darkened. The shadow caster is inset 0.5 pt so its anti-aliased rim
  lies inside the cut-out; the cut-out is the exact shape so no bright seam
  opens next to the hairline (that seam was measured at one pixel on the
  first capture and is what motivated the inset). Verified by rendering:
  `PanelFrameTests.testOutsideShadowNeverDrawsInsideTheShape`,
  `testShadowCasterInsetHidesItsRimWithoutOpeningASeam`. Pixel evidence on the
  Light Solid capture: interior 255, edge 240, then 243 → 245 → 248 → 251 →
  255 over the 24 pt margin, no gap.
- **Control outlines:** native-glass controls (composer field, pin, mode dock,
  round buttons, view switches) carry a `Color.primary` outline at 0.10 / 0.75 pt
  on every surface (Increased Contrast 0.20 / 1 pt). The Reduce Transparency
  (opaque) control path keeps its existing edge.
  `PanelFrameTests.testNativeGlassControlsCarryAFaintOutlineOnEverySurface`.
  On this machine the composer field measured 236 on the 255 Solid surface
  both before and after; the outline adds a 221 rim. The brief's 253 reading
  shows native glass can render far lighter (activation, OS), which is what the
  outline guards against.
- The window keeps `panelUsesSystemShadow = false` and the 24 pt
  `panelElevationMargin`; the outer corners stay transparent and click-through
  and the margin is never a resize grip.

### 2.2 Accessibility

- Reduce Transparency → `kind = .solid` with the chosen Depth and Tint kept
  (`testReduceTransparencyRendersSolidButKeepsDepthAndTint`).
- Increased Contrast → edge and control outlines one step stronger; the
  composite the tint table depends on is unchanged
  (`testIncreasedContrastChangesNothingTheTableDependsOn`).
- Reduce Motion → the surface, depth and tint crossfade is `nil`
  (`AtticPanelSurface.surfaceAnimationIdentity`).

## 3. Depth

`PanelDepthCrown`: a linear gradient with exactly the owner's stops, opacity
0.82 @ 0.00, 0.58 @ 0.42, 0.18 @ 0.74, 0.02 @ 1.00, top to bottom; black in
Dark, white in Light; clipped to the squircle; drawn above the fill and below
the tint. It applies to every surface and palette and never changes the
foundation. `testDepthCrownUsesTheExactStops`,
`testDepthAppliesToEverySurfaceAndPaletteAndKeepsTheFloor`.

Everything about Depth is `PanelDepthCrown` + `PanelDepthCrownView`, the
`depth` field of the treatment, and `AppSettings.panelDepthEnabled`; removing
it is those three places plus the Settings toggle.

Fidelity to the old Original Dark Clear: see §7.

## 4. Tint

The wash is the palette accent's hue at HSV saturation 0.85 and value 1.0
(Light) / 0.95 (Dark), fading linearly from its top opacity at the top edge to
nothing at 60 % of the panel height, clipped to the squircle.

### 4.1 Calibration method

For each cell (palette × mode × surface × depth), and each step:

1. **Base composite** at the top edge (location 0): worst-case backdrop
   (black for Light, white for Dark) → foundation (`opaqueSurface` at the
   foundation opacity; 1 for Solid) → Depth crown at 0.82 when Depth is on.
2. **Solve** the top opacity α by bisection so that ΔE76 (CIE Lab, D65)
   between the base and `base mixed α with wash` equals the target: Subtle 3,
   Vivid 7, Bold 12.
3. **Clamp**: if primary or secondary foreground contrast against the tinted
   composite falls below 4.75:1, bisect α down until it holds and mark the
   cell clamped. Readability always wins.
4. Store α to three decimals (rounded down when clamped) with the ΔE it
   actually produces.

Blending is sRGB source-over in gamma space, the same arithmetic as the
foundation solver and the existing readability tests. The table is
`PanelTintCalibration.table`, generated by `PanelTintCalibration.solveTable()`
and pasted into the source (run `PanelTintCalibrationTests` with
`ATTIC_PRINT_TINT_TABLE=1`). Nothing solves at draw time.

Tests: `testTableHasEveryCell` (252 cells),
`testEveryCellReproducesItsTargetDifferenceAndKeepsTextReadable` (independent
Lab implementation, ΔE ± 0.25 for unclamped cells, ≥ 4.75:1 at the top edge
and ≥ 4.5:1 at every location over the eight desktop extremes),
`testTableMatchesTheSolver`, `testGlassCellsHoldTheirStrengthOverAMidGreyBackdropToo`
(the same α over a mid-grey desktop stays within 0.5×–1.8× of the solved ΔE
and keeps the floor), and the Solid-without-Depth cells agree with the
prototype's `tint-calibration-prototype.json` within 0.002.

Increased Contrast needs no second table: it changes only `edgeTint` and the
selection opacities, none of which the composite depends on.

### 4.2 Cells that clamp

No Solid cell clamps, and no cell with Depth on clamps. On Glass and Frosted
**without Depth** the foundation already sits exactly at the 4.75:1 floor over
the worst-case backdrop, so a saturated wash of any strength breaks it and
the solver clamps the step to what the floor allows. Where the surface luminance
happens to leave headroom (Porcelain Vapor Light, Smoked Umber Light, Sea Glass
Light, Midnight Cobalt Dark, Amethyst Dark) the steps calibrate normally.

| Cell (Glass and Frosted behave identically) | Subtle | Vivid | Bold |
|---|---|---|---|
| Original · Light | α 0.023, ΔE 1.83 | same | same |
| Original · Dark | α 0.011, ΔE 0.87 | same | same |
| Midnight Cobalt · Light | α 0.029, ΔE 2.50 | same | same |
| Porcelain Vapor · Dark | α 0.001, ΔE 0.07 | same | same |
| Smoked Umber · Dark | α 0.023, ΔE 2.04 | same | same |
| Electric Blue · Light | ΔE 3.02 (not clamped) | α 0.044, ΔE 3.41 | same |
| Electric Blue · Dark | α 0.016, ΔE 1.20 | same | same |
| Sea Glass · Dark | α 0.005, ΔE 0.46 | same | same |
| Amethyst · Light | ΔE 3.05 (not clamped) | α 0.030, ΔE 3.82 | same |

In words: **on Glass or Frosted with Depth off, Tint is nearly invisible on
Original, Electric Blue, and the Dark modes of Porcelain Vapor, Smoked Umber
and Sea Glass, and Vivid/Bold collapse to Subtle on Midnight Cobalt Light,
Electric Blue Light and Amethyst Light.** With Depth on, every step reaches its
target on every palette and surface. This follows directly from the brief's
rule (clamp to the floor over the worst-case backdrop) and is the honest
consequence of a foundation solved to the minimum readable opacity.

The Settings preview shows the real result, and the Appearance pane says so
when the chosen cell is clamped. If the owner wants Tint to reach its target
on Glass without Depth, the alternative is a tint-aware foundation (raise the
foundation just enough for the tinted top edge to keep 4.75:1), which trades a
few percent of transparency for the colour; that is a small, separate change
(`PanelTintCalibration.solve` plus `minimumReadableOpacity`) and is not done here.

## 5. Migration

`AppearanceMigration.migrateIfNeeded` runs in `AppSettings.init` before any
appearance key is read, on whatever `UserDefaults` the settings were given
(the isolated test suites included). It is a no-op once
`appearanceSchemaVersion` is 2.

| Old state | New state |
|---|---|
| no stored appearance key at all (fresh install) | Surface Glass, **Depth on**, Tint Off (Mode System and Palette Original are the read defaults) |
| `isTranslucent == false` | Solid, Depth off |
| `panelGlassStyle == frosted` | Glass, Depth off |
| `panelGlassStyle == stable` or `liveStable` (Glassmorphism) | Frosted, Depth off |
| `panelGlassStyle == clear` (or missing: the old default) and palette Original | Glass, **Depth on** |
| `panelGlassStyle == clear` (or missing) and a custom palette | Glass, Depth off |
| unknown `panelGlassStyle` spelling | treated as `clear` (the old loader's fallback) |
| gradient coverage 0 | Tint Off |
| gradient coverage > 0 (or missing: old default 0.55) | Tint = the step matching the old top-edge ΔE in Light (pole white mixed 12 % with the tint colour, drawn at 0.82 over the palette's Light `opaqueSurface`): < 3 Off, 3–5 Subtle, 5–9.5 Vivid, ≥ 9.5 Bold |
| custom gradient colour | used for that ΔE, then discarded |

What that gives real installs: every palette's own gradient computes below
ΔE 3 except Electric Blue in Light (ΔE ≈ 5.6 → Vivid), so almost everyone keeps
Tint Off; a saturated custom colour (pure red ≈ 11.3, black ≈ 8.7 on Original)
becomes Bold or Vivid.

After mapping, the four obsolete keys are removed and the schema version
written. Tests: `AppearanceMigrationTests` (pure matrix, defaults round trip,
idempotence including "old key reappears", fresh install through `AppSettings`,
custom colour → step → discarded, unknown future values not destroyed).

Launch arguments for previews and UI tests use the new keys with plist
syntax: `-panelSurfaceStyle glass -panelDepth '<true/>' -panelTint vivid
-panelTheme amethyst -appearancePreference dark`.

## 6. Subtask checklist windows

See `PanelSurfaceWindow` (`Attic/Window/PanelSurfaceHostingView.swift`): the
transient and pinned checklists carry the same 24 pt transparent margin as the
main panel, the same `visibleContentFrame` / `nativeFrame(forVisibleFrame:)` /
`setVisibleContentFrame` conversions, an accessibility frame equal to the
visible frame, click-through outside the squircle, and render through the
same `atticPanelSurface(showsElevation: true)`. Persisted pinned frames stay
visible-frame based. Details and tests are listed in the PR.

## 7. Original Dark: old Clear versus Glass + Depth

The old Clear surface was clear Liquid Glass with a black 0.06 tint, no
foundation, and the crown. Glass is `.regular` Liquid Glass under the
readable foundation (Original Dark: 66 %). With Depth on, the crown is
identical; the lower half is as clear as the foundation allows, which is what
the readability floor requires. The side-by-side captures over the busy
backdrop are in the PR. A lighter foundation under Depth was considered and
rejected: the crown is 0.02 at the bottom edge, so the floor at the bottom
needs the same foundation with or without Depth, and a location-varying
foundation would couple Depth to the fill the brief asks to keep separate.
