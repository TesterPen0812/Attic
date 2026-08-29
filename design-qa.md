# Tasks Shell Design QA

## Evidence

- Source visual truth: `/Users/taha/.codex/generated_images/01a046b6-a34d-75c3-8006-3eb1a7036e06/exec-67eecc4d-a20e-4393-ba72-8714c821d01c.png`
- Rendered implementation: `/Users/taha/.codex/worktrees/attic-siri-shell/.build/visual-qa/tasks-native-glass-corrected-sizing.png`
- Normalized full-panel comparison: `/Users/taha/.codex/worktrees/attic-siri-shell/.build/visual-qa/tasks-reference-comparison-corrected-sizing.png`
- Source pixels: `1060 x 1484`; focused panel crop: `920 x 1340`; normalized crop: `824 x 1200`.
- Implementation pixels: `3600 x 2338` at macOS Retina density; panel frame: `337 x 489 pt`; panel crop: `674 x 978 px`; normalized crop: `827 x 1200`.
- Viewport: `1800 x 1169 pt` (`3600 x 2338 px`, `2x`).
- Density normalization: both panel crops were independently scaled to 1200 px high and placed in one `1675 x 1200` comparison image.
- State: dark Tasks workspace with the panel revealed at the top-right. The reference contains `1 / 2 / 1` tasks while the isolated preview preserves its existing `1 / 6 / 0` local test data. Item labels and counts are therefore excluded from pixel-exact judgments; shell, controls, type hierarchy, section rhythm, task rows, and glass treatment are directly comparable.

## Findings

No actionable P0, P1, or P2 visual mismatch remains after the final comparison.

The source and implementation now share the accepted compact panel proportion, large squircle, pin control, four-mode glass dock, direct grouped task rows, and bottom quick-entry composition. The surface has the reference's near-black crown and progressively clearer lower half while retaining Apple's native clear Liquid Glass as the optical backdrop.

### Required fidelity surfaces

- Fonts and typography: system/rounded system typography preserves the source hierarchy; section labels are secondary, active rows are legible, and row titles do not truncate unnecessarily.
- Spacing and layout rhythm: panel ratio and original control sizing were retained at the product owner's direction. Persistent controls remain clear of the adjustable squircle, and task content scrolls independently between top chrome and bottom entry.
- Colors and visual tokens: dark crown, clear lower glass, restrained white foregrounds, semantic priority rings, and native glass controls match the selected direction. Contrast remains readable over both light and dark desktop content.
- Image quality and asset fidelity: the design contains no custom image assets. All interface symbols use native SF Symbols, and the backdrop distortion is native Liquid Glass rather than a raster or simulated refraction layer.
- Copy and content: persistent UI copy matches the target (`In Progress`, `To do`, `Done`, and `Add a task, note, or idea`). Preview task titles differ because the isolated local store is intentionally preserved.

## Full-view comparison evidence

The final normalized comparison shows equivalent panel proportions and accepted control sizing. The implementation is slightly more background-dependent than the static generated source because real Liquid Glass continuously samples the live desktop; that variance is intentional and is the requested native behavior.

## Focused-region comparison evidence

A second focused crop was not required: the normalized comparison contains only the two panel surfaces, at nearly identical dimensions, and the top dock, task rows, status marks, and bottom entry controls are all clearly readable at 1200 px high.

## Comparison history

1. **P1 — Flat mid-gray surface.** The first implementation used a strong uniform black tint and appeared like a gray material slab. The native glass tint was reduced and a black-to-clear lighting gradient was placed behind the foreground. Post-fix evidence: `tasks-reference-comparison-corrected-sizing.png`.
2. **P2 — Panel too tall in an early build.** The Tasks workspace was changed to a stable height of `1.45 x` its content width, matching the selected compact workboard proportion. Post-fix evidence: the final implementation panel is `337 x 489 pt`.
3. **P2 — Foreground dimmed with the surface.** The lighting gradient originally composited above the content. It was moved into the surface background and task foreground tokens were made explicit. Post-fix evidence: section labels, titles, rings, and menus remain readable in the final capture.
4. **Tentative chrome-scale change rejected.** A later comparison led to a provisional reduction in control and row sizes. The product owner confirmed the original sizing was correct, so every such geometry change was reverted. Only the optical surface correction remains.

## Interaction and regression evidence

- Native pin button, four-mode dock, status actions, row menus, scrolling, quick entry, and expanded task options remain wired to existing application behavior.
- Local-only preview build succeeded with `ATTIC_LOCAL_ONLY`, no CloudKit or APNs entitlements, and isolated bundle identifier `com.taha.Attic.tasks-shell`.
- macOS unit suite: 222 tests, 0 failures.
- Generated Xcode project: repeatable and current using the repository's Homebrew Ruby/Bundler toolchain.
- Manual UAT still recommended: exercise the exact user's real task titles and priority mix, then inspect the live glass over several desktop backgrounds.

## Follow-up polish

- P3: repeat the capture with the same `1 / 2 / 1` content state if a pixel-level task-density comparison is needed. This should not mutate or reset the existing isolated preview store merely for a screenshot.

final result: passed
