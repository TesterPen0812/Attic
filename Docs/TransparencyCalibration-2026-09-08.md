# Transparency calibration — candidate, not final visual approval

This continues the readable-themes work after the user clarified that the goal
is the most transparent usable middle ground, not a conservative Frosted fallback.

## Candidate

- Preserve the Clear eligibility rule (Original + effective Dark only).
- Strengthen secondary foregrounds from 0.80 to 0.90 in Dark and 0.20 to 0.12 in
  Light. Size and weight retain hierarchy without requiring such a heavy fill.
- Replace blanket 82% Dark / 74% Light Frosted foundations with the first whole
  percentage point meeting a 4.75:1 source-over contrast target for each palette.
- Remove the additional native Frosted tint; the foundation and gradient already
  supply the theme color. Keep regular native glass's blur.
- The same minimum foundation calculation applies to Glassmorphism, replacing
  its former 80% / 72% values. Opaque and Reduce Transparency remain fully opaque.
- Original Clear's background-rendering path is unchanged; the shared caption
  foreground strengthening also applies there.

| Preset | Dark fill | Light fill |
| --- | --- | --- |
| Original | 66% | 56% |
| Midnight Cobalt | 66% | 57% |
| Porcelain Vapor | 69% | 56% |
| Smoked Umber | 67% | 58% |
| Electric Blue | 66% | 55% |
| Sea Glass | 68% | 57% |
| Amethyst | 67% | 57% |

These are the additional foundation opacities, **not total panel opacity or
measured optical transmission**. Native material contributes its own treatment.
The solver intentionally does not assume a guaranteed native-material opacity.
Consequently this is the minimum under the stated independent contrast model,
not proof that every lower native-glass setting is unusable.

## Evidence so far

`transparency-full-1.xcresult` under `.build/evidence/`: 547 unit tests passed,
zero runtime warnings. Existing RGB-extreme, gradient, theme, and accessibility
policy tests remain intact. The added boundary test proves that the chosen fill
meets 4.75:1 while one percentage point less fails that target. It does not assert
that one percentage point less necessarily fails the lower 4.5:1 threshold.

A temporary native SwiftUI comparison fixture was built in
`.build/evidence/TransparencyProbe.swift`. It compared regular native glass with
0%, 35%, and the prior heavy fill, plus a clear native base with lighter fills and
stronger captions. Bright, dark, and checkerboard backgrounds were inspected.
Bare regular glass made small text faint on opposite-color backgrounds. Clear
base samples transmitted background lettering that competed with foreground
text when active, despite looking more blurred in immediate inactive captures.
The latter discrepancy is why cached/immediate captures cannot establish the
final active-window result. The fixture is diagnostic, not the actual Attic panel.

One saved native active-window comparison (Light over black) is at
`/var/folders/sz/xk9_gmgj32g6vb3c287hzrfh0000gn/T/codex-shot-2026-09-08_04-32-17.png`.
The temp location is not durable evidence storage.

## Pending gate

The actual panel still needs an uninterrupted active/inactive comparison across
bright, dark, and busy backgrounds, with populated Tasks/Notes/Canvas, at zero
gradient and the normal gradient. Lower native-glass candidates must be compared
before declaring a practical transparency limit. The desktop captures were
interrupted by hidden windows, and preview UI input reported user-change guards.
No final all-background or maximum-transparency claim is made.

Isolated candidate app:
`/Users/taha/Developer/attic-recovery-20260907/.build/BalancedGlassPreview/Build/Products/Local/AtticBalancedGlassPreview.app`

Bundle `com.taha.Attic.balancedglass20260908.preview`; executable
`AtticBalancedGlassPreview`. Previous previews and user stores are preserved.
The first diagnostic launch uses argument-domain defaults for Dark, Frosted,
and gradient coverage 0. Build provenance is in `PreviewState/manifest.txt`.
This remains macOS-only and local-only; no release or performance certification.
