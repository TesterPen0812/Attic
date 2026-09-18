# Readable themes validation — 8 September 2026

## Scope and provenance

Implementation branch: `codex/attic-readable-themes-20260908`.
Validated source commit: `0613ba441fcfa379da11f7331bcf16ace37576cb`.
Baseline: `9a9f7dd7e1985010f4d2bb5c34ba54b3829ac56a`.
Checkout: `/Users/taha/Developer/attic-recovery-20260907`.

Clear is selectable only for Original with effective Dark appearance. Other
combinations resolve a stored Clear preference to Frosted without erasing it.
The rejected localized text-backplate experiment remains unmerged.

Non-Clear surfaces use appearance-specific readable foundations and explicit
foreground colors. Tasks, Notes, Canvas controls, captions, and prompts use
appropriate foregrounds. Gradient coverage persists from 0–100%, with a custom
color and theme-color reset. Original Dark Clear retains its original lighting;
gradient customization is disabled in that state. Native Picker writes are
deferred outside view-update callbacks, with equality and availability guards.

## Verification

Evidence is under `.build/evidence/` in this checkout.

| Check | Result |
| --- | --- |
| Full macOS unit suite, final source (`readable-themes-full-3.xcresult`) | 546 passed, 0 failures, 0 runtime warnings |
| Native appearance/glass transitions (`readable-themes-picker-1.xcresult`) | Passed, 0 runtime warnings |
| Seven presets × Light/Dark, Clear fallback/restoration, opaque toggle, gradient endpoints (`readable-themes-ui-4.xcresult`) | Passed, 0 runtime warnings; 17 screenshots exported |
| Focused exact gradient endpoint test (`readable-themes-endpoints-1.xcresult`) | Passed before the Picker warning fix; that earlier run had a runtime warning |
| Project-generation verifier | Passed; no project inputs added |
| Diff whitespace check | Passed |

Earlier iterations exposed a genuinely selectable unavailable Clear segment,
slider automation stopping at 1%/99%, and synchronous native Picker publishing
warnings. The final UI run passes after fixing these, without suppressing
warnings or weakening endpoint assertions. An earlier full unit run had three
gesture-test failures in unchanged geometry code; two later complete runs passed.
An input-state interaction is plausible but was not conclusively recorded.

Native screenshots were reviewed across all 14 appearance/preset combinations
in the prior capture, and final gradient-off/full-coverage and Light renders
were rechecked. Text and prompts remain visible at both gradient endpoints;
the top gradient changes independently of the readable foundation. Modeled
contrast and sampled screenshot pixels are not arbitrary-backdrop guarantees.

## Preview and remaining UAT

Preview bundle: `com.taha.Attic.readablethemes20260908.preview`.
Executable: `AtticReadableThemesPreview`.
App: `/Users/taha/Developer/attic-recovery-20260907/.build/ReadableThemesPreview/Build/Products/Local/AtticReadableThemesPreview.app`.
Build provenance and signature are recorded in that derived-data directory's
`PreviewState/manifest.txt` and `entitlements.plist`.

Original Dark Clear deliberately remains backdrop-dependent: the captured bright
background reduced caption/prompt contrast. This is a known preserved exception,
not an all-background readability pass. Frosted and Glassmorphism foundations
favor readability; perceived transparency still needs user approval.

Remaining manual UAT: all surfaces with populated content across desktop
backgrounds, custom color-picker interaction, Glassmorphism/opaque combinations,
system appearance changes, VoiceOver, physical trackpad/drag behavior, and
performance during real use. No exhaustive visual, accessibility, or performance
certification is claimed. This is an isolated local-only macOS preview; no
CloudKit, APNs, iPhone, TestFlight, Production, or release-readiness claim.
