# Round D3 — native caret geometry

Measurement and design only. Branch `phase-x/d2`, based on D2 head `6f875428`. No product source changed.

**Recommend E-shell as the geometry to take into the fix round:** natural AppKit line boxes, calibrated `lineSpacing`, and an equal transfer from the layout fragment's bottom margin to its top margin. It gives the stock/TextEdit-height native caret, preserves R14 pitches, and preserves the existing glyph baselines on typed lines, isolated empty lines, empty tails after typed text, and the first and middle wrapped lines. It never touches an insertion indicator.

**It is not a complete acceptance result.** An internal blank paragraph still produces an inflated caret and a short preceding baseline interval. Also, stock AppKit is centred approximately on the font's natural ascender/descender band, not exactly on its visible ink. None of the measured variants satisfies **all** the requested cases with exact ink centring. The fix round must retain these two distinctions; deleting `NoteCaretFit` alone is insufficient, and this report does not authorize calling either discrepancy fixed.

## Evidence and coordinate definitions

Read D2's tracked [O18-03 inventory and plan](../Docs/Diagnostics/RoundD2/round-d2-report.md#o18-03--complete-caret-customization-inventory), its stock harness, and the original owner-feedback files in `/Users/taha/Projects/attic/attic-redesign-assets/phaseX/`. F-03, F-03b, F-03c and O14-10 are requirements, not superseded by D2's stock comparison.

The D3 harness reproduces D2's unshown key-status window technique with plain `NSTextView(usingTextLayoutManager: true)`, using `isRichText = false` like D2 and the product, with explicit attributed fonts/styles. It enumerates actual `NSTextInsertionIndicator` subviews and converts their public frames into text-view coordinates. No replacement indicator, fitter, frame observer, or product editor is involved. All host windows remain invisible at (-9000, -9000); no screen access, app activation, owner application/store, or subagents. Only the prohibited-activation XCTest host `org.attic.d3.unithost` runs, executable `AtticD3UnitHost`. The build's application override is `org.attic.d3.measurement`; tests use `org.attic.d3.tests`. These are not owner identities.

Environment: macOS 27.0 (26A5425a), SDK 27.0, arm64, 2x cached bitmaps. This is not validation of macOS 26 or a live Apple Notes/TextEdit session. Fonts come from `NoteTextStyle.font(for:)`, including the actual variable-weight headings, plus the real title, small-heading, Mono and table-header faces.

- **A means today's fixed-height layout inputs, with fitting absent.** It does not mean today's already-shortened product caret. Custom block gaps are omitted to isolate line geometry; their source-derived integration changes are below.
- Coordinates are flipped text-view points, with container origin `(24,16)` and zero horizontal fragment padding. All frames include that origin. For typed lines the insertion offset is after the first `H`; empty lines use their actual insertion location. Full x/y/width/height/bottom are in the CSV/JSON. Public indicator width is zero, the insertion anchor; measured visible stroke width is **4 px / 2 pt** for A, B-calibrated, E-shell and F in all four primary fonts.
- `N = ascender - descender + leading`, using the signed negative font descender. `R` is AppKit's **measured default line-box height**, not `ceil(N)`. `P` is the required R14 pitch; `S = P - R`.
- Ink-band top/bottom are `baseline - capHeight` and `baseline - descender`. This is the requested cap-to-font-descender metric band, not a claim that every glyph reaches both edges. The x-height band is `[baseline - xHeight, baseline]`. Both are virtual bands on an empty line.
- Room difference is `(bandTop - caretTop) - (caretBottom - bandBottom)`. Positive means more space above: the caret centre is **above** that band's centre by half the reported difference. Negative room on one side means that band extends beyond the caret.
- `Δtext` is glyph-baseline displacement from A for the same font/fixture, positive downward. It includes any `.baselineOffset`; it does not confuse the layout baseline with the raised glyph baseline.
- `typed` is the first of three explicit paragraphs. `empty` is the middle insertion line of `"\n\n"`. `isolated-empty` is `""`; `trailing-empty` is the last line of `"Hxgj py\n"`. Wrapped first/middle are visual line indices 0 and 2 of a long single paragraph. A CSV pitch of zero means no neighbour exists, not a zero-height line.

The complete **432-row table**, including every variant/fixture's actual frame, both adjacent baseline intervals, both ink bands, all room differences, selection segment, natural-height excess and visual displacement, is [geometry.csv](round-d3/geometry.csv). [measurements.json](round-d3/measurements.json) also preserves all neighbouring lines. The 504 original native renders and their attachment identities are in [renders](round-d3/renders/) and [the manifest](round-d3/render-manifest.json). Summary tables follow; no unsuccessful option is silently omitted.

## Font metrics and the native reference

| Role | Font | pt | Asc | Desc | Lead | Cap | x-height | N | Default R |
|---|---|---|---|---|---|---|---|---|---|
| body | .AppleSystemUIFont | 12.500 | 12.085 | -2.637 | 0.000 | 8.807 | 6.580 | 14.722 | 15.000 |
| h1 | .SFNS-Semibold | 16.500 | 15.952 | -3.480 | 0.000 | 11.626 | 8.838 | 19.433 | 19.000 |
| h2 | .SFNS-Semibold | 15.000 | 14.502 | -3.164 | 0.000 | 10.569 | 8.035 | 17.666 | 18.000 |
| h3 | .SFNS-Semibold | 13.500 | 13.052 | -2.848 | 0.000 | 9.512 | 7.231 | 15.899 | 16.000 |
| title | .AppleSystemUIFontBold | 18.500 | 17.886 | -3.902 | 0.000 | 13.035 | 9.927 | 21.788 | 22.000 |
| h4-h6 | .SFNS-Semibold | 12.500 | 12.085 | -2.637 | 0.000 | 8.807 | 6.696 | 14.722 | 15.000 |
| mono | .AppleSystemUIFontMonospaced-Regular | 11.000 | 10.635 | -2.320 | 0.000 | 7.750 | 5.817 | 12.955 | 13.000 |
| table-header | .AppleSystemUIFontDemi | 12.500 | 12.085 | -2.637 | 0.000 | 8.807 | 6.671 | 14.722 | 15.000 |

The native reference's rounding matters. For H1, `N = 19.4326` but **R = 19**, whereas for Body `N = 14.7217` and **R = 15**. Therefore `lineSpacing = P - N` misses both pitches in opposite directions. Probe the actual font/layout policy; do not hard-code a rounding formula from this OS.

## Variants and typed-line table

| Variant | Actual experimental inputs |
|---|---|
| A-fixed | Minimum and maximum line height = P, no extra spacing. |
| B-spacing | No fixed height; line spacing = P − N. |
| B-calibrated | No fixed height; line spacing = P − measured R. |
| C-baseline | A plus positive baseline offset `P − round(-descender) − ((P−N)/2 + ascender)`, centring the natural font band in the original fixed box. |
| D-multiple | No fixed height; line-height multiple = P/N. |
| E-no-leading | `usesFontLeading = false`, spacing = P − (ascender − descender). |
| E-paragraph | Default line height, paragraph spacing = P − N, no line spacing. |
| E-fixed-spacing | Fixed R, plus line spacing = P − R. |
| E-typographic | A, with public fragment/line-fragment subclasses reporting a natural-height band centred on the cap/descender band. Stable proxy identities, character mapping and both fragment lookup methods are supplied. **Rejected experiment**, not a supported recipe. |
| E-natural-baseline | B-calibrated plus a baseline offset equal to half F's ink-room difference. Tests whether raising glyphs can optically centre an otherwise natural caret. |
| E-hybrid | B-calibrated for non-empty paragraphs; empty stored paragraphs use zero line spacing and paragraph spacing S. Pending blank-tail typing attributes request space before. |
| E-before | B-calibrated with paragraph space before S and space after −S; blank stored paragraphs have no line spacing or space after. Same pending-tail experiment. |
| E-shell | B-calibrated, native layout fragment `topMargin += S`, `bottomMargin -= S`; line fragments remain AppKit's originals. |
| F-default | Unmodified default paragraph style and the same font; TextEdit-style reference. |

Frames are `(y, height)`. `h−N`, room differences and Δtext are points. Selection highlight height equals the native caret height for these valid typed-line rows. The failed proxy is marked INVALID even though its public `typographicBounds` looks desirable.

| Font | Variant | Caret (y,h) | Pitch | Ink baseline | h−N | Room ink | Room x | Δtext |
|---|---|---|---|---|---|---|---|---|
| body | A-fixed | (16.000, 18.500) | 18.500 | 31.500 | 3.778 | 6.329 | 5.920 | 0.000 |
| body | B-spacing | (16.000, 15.000) | 18.778 | 28.000 | 0.278 | 2.829 | 2.420 | -3.500 |
| body | B-calibrated | (16.000, 15.000) | 18.500 | 28.000 | 0.278 | 2.829 | 2.420 | -3.500 |
| body | C-baseline | (16.000, 16.974) | 16.974 | 29.974 | 2.252 | 4.803 | 4.395 | -1.526 |
| body | D-multiple | (16.000, 18.850) | 18.850 | 31.850 | 4.128 | 6.679 | 6.270 | 0.350 |
| body | E-no-leading | (16.000, 15.000) | 18.778 | 28.000 | 0.278 | 2.829 | 2.420 | -3.500 |
| body | E-paragraph | (16.000, 15.000) | 18.778 | 28.000 | 0.278 | 2.829 | 2.420 | -3.500 |
| body | E-fixed-spacing | (16.000, 15.000) | 18.500 | 28.000 | 0.278 | 2.829 | 2.420 | -3.500 |
| body | E-typographic | (0.000, 0.000) INVALID | 18.500 | 31.500 | -14.722 | 56.829 | 56.420 | 0.000 |
| body | E-natural-baseline | (16.000, 15.000) | 18.500 | 28.000 | 0.278 | 2.829 | 2.420 | -3.500 |
| body | E-hybrid | (16.000, 15.000) | 18.500 | 28.000 | 0.278 | 2.829 | 2.420 | -3.500 |
| body | E-before | (16.000, 15.000) | 18.500 | 28.000 | 0.278 | 2.829 | 2.420 | -3.500 |
| body | E-shell | (19.500, 15.000) | 18.500 | 31.500 | 0.278 | 2.829 | 2.420 | 0.000 |
| body | F-default | (16.000, 15.000) | 15.000 | 28.000 | 0.278 | 2.829 | 2.420 | -3.500 |
| h1 | A-fixed | (16.000, 21.000) | 21.000 | 34.000 | 1.567 | 6.855 | 6.162 | 0.000 |
| h1 | B-spacing | (16.000, 19.000) | 20.567 | 32.000 | -0.433 | 4.855 | 4.162 | -2.000 |
| h1 | B-calibrated | (16.000, 19.000) | 21.000 | 32.000 | -0.433 | 4.855 | 4.162 | -2.000 |
| h1 | C-baseline | (16.000, 19.736) | 19.736 | 32.736 | 0.303 | 5.591 | 4.898 | -1.264 |
| h1 | D-multiple | (16.000, 20.532) | 20.532 | 33.532 | 1.100 | 6.387 | 5.694 | -0.468 |
| h1 | E-no-leading | (16.000, 20.000) | 21.567 | 32.000 | 0.567 | 3.855 | 3.162 | -2.000 |
| h1 | E-paragraph | (16.000, 19.000) | 20.567 | 32.000 | -0.433 | 4.855 | 4.162 | -2.000 |
| h1 | E-fixed-spacing | (16.000, 19.000) | 21.000 | 32.000 | -0.433 | 4.855 | 4.162 | -2.000 |
| h1 | E-typographic | (0.000, 0.000) INVALID | 21.000 | 34.000 | -19.433 | 59.855 | 59.162 | 0.000 |
| h1 | E-natural-baseline | (16.000, 19.000) | 21.000 | 32.000 | -0.433 | 4.855 | 4.162 | -2.000 |
| h1 | E-hybrid | (16.000, 19.000) | 21.000 | 32.000 | -0.433 | 4.855 | 4.162 | -2.000 |
| h1 | E-before | (16.000, 19.000) | 21.000 | 32.000 | -0.433 | 4.855 | 4.162 | -2.000 |
| h1 | E-shell | (18.000, 19.000) | 21.000 | 34.000 | -0.433 | 4.855 | 4.162 | 0.000 |
| h1 | F-default | (16.000, 19.000) | 19.000 | 32.000 | -0.433 | 4.855 | 4.162 | -2.000 |
| h2 | A-fixed | (16.000, 20.000) | 20.000 | 33.000 | 2.334 | 6.595 | 5.965 | 0.000 |
| h2 | B-spacing | (16.000, 18.000) | 20.334 | 31.000 | 0.334 | 4.595 | 3.965 | -2.000 |
| h2 | B-calibrated | (16.000, 18.000) | 20.000 | 31.000 | 0.334 | 4.595 | 3.965 | -2.000 |
| h2 | C-baseline | (16.000, 18.669) | 18.669 | 31.669 | 1.003 | 5.264 | 4.634 | -1.331 |
| h2 | D-multiple | (16.000, 20.378) | 20.378 | 33.378 | 2.712 | 6.973 | 6.343 | 0.378 |
| h2 | E-no-leading | (16.000, 19.000) | 21.334 | 31.000 | 1.334 | 3.595 | 2.965 | -2.000 |
| h2 | E-paragraph | (16.000, 18.000) | 20.334 | 31.000 | 0.334 | 4.595 | 3.965 | -2.000 |
| h2 | E-fixed-spacing | (16.000, 18.000) | 20.000 | 31.000 | 0.334 | 4.595 | 3.965 | -2.000 |
| h2 | E-typographic | (0.000, 0.000) INVALID | 20.000 | 33.000 | -17.666 | 58.595 | 57.965 | 0.000 |
| h2 | E-natural-baseline | (16.000, 18.000) | 20.000 | 31.000 | 0.334 | 4.595 | 3.965 | -2.000 |
| h2 | E-hybrid | (16.000, 18.000) | 20.000 | 31.000 | 0.334 | 4.595 | 3.965 | -2.000 |
| h2 | E-before | (16.000, 18.000) | 20.000 | 31.000 | 0.334 | 4.595 | 3.965 | -2.000 |
| h2 | E-shell | (18.000, 18.000) | 20.000 | 33.000 | 0.334 | 4.595 | 3.965 | 0.000 |
| h2 | F-default | (16.000, 18.000) | 18.000 | 31.000 | 0.334 | 4.595 | 3.965 | -2.000 |
| h3 | A-fixed | (16.000, 18.500) | 18.500 | 31.500 | 2.601 | 5.836 | 5.269 | 0.000 |
| h3 | B-spacing | (16.000, 16.000) | 18.601 | 29.000 | 0.101 | 3.336 | 2.769 | -2.500 |
| h3 | B-calibrated | (16.000, 16.000) | 18.500 | 29.000 | 0.101 | 3.336 | 2.769 | -2.500 |
| h3 | C-baseline | (16.000, 17.352) | 17.352 | 30.352 | 1.453 | 4.688 | 4.121 | -1.148 |
| h3 | D-multiple | (16.000, 18.617) | 18.617 | 31.617 | 2.718 | 5.953 | 5.386 | 0.117 |
| h3 | E-no-leading | (16.000, 16.000) | 18.601 | 29.000 | 0.101 | 3.336 | 2.769 | -2.500 |
| h3 | E-paragraph | (16.000, 16.000) | 18.601 | 29.000 | 0.101 | 3.336 | 2.769 | -2.500 |
| h3 | E-fixed-spacing | (16.000, 16.000) | 18.500 | 29.000 | 0.101 | 3.336 | 2.769 | -2.500 |
| h3 | E-typographic | (0.000, 0.000) INVALID | 18.500 | 31.500 | -15.899 | 56.336 | 55.769 | 0.000 |
| h3 | E-natural-baseline | (16.000, 16.000) | 18.500 | 29.000 | 0.101 | 3.336 | 2.769 | -2.500 |
| h3 | E-hybrid | (16.000, 16.000) | 18.500 | 29.000 | 0.101 | 3.336 | 2.769 | -2.500 |
| h3 | E-before | (16.000, 16.000) | 18.500 | 29.000 | 0.101 | 3.336 | 2.769 | -2.500 |
| h3 | E-shell | (18.500, 16.000) | 18.500 | 31.500 | 0.101 | 3.336 | 2.769 | 0.000 |
| h3 | F-default | (16.000, 16.000) | 16.000 | 29.000 | 0.101 | 3.336 | 2.769 | -2.500 |

### What the native inputs actually do

**B-calibrated:** the right natural caret and exact wrapped pitch, but glyphs move up by S. B-spacing instead yields pitches 18.7783 / 20.5674 / 20.3340 / 18.6006 for Body/H1/H2/H3. The difference accumulates across wrapped lines; it is not merely a first-line offset.

**C:** baseline offset is not independent of native line geometry. With the original fixed min/max, AppKit reduces the line-box height and pitch by the positive offset: Body becomes **16.9741**, H1 **19.7358**, H2 **18.6689**, H3 **17.3521**. This raises the glyphs but neither retains R14 pitch nor produces the desired natural-height/ink-centred caret. The natural-height baseline-offset control changes the layout baseline and the glyph offset together, leaving the visible glyph/caret relationship unchanged. A `.baselineOffset` is not a free optical translation.

**D:** P/N multiplies AppKit's rounded default line box, not the raw metric sum. Calibrating against R could restore pitch, but would still make the caret that full multiplied height; it would not separate natural caret height from leading.

**E-no-leading:** these SF fonts report zero leading, yet toggling the layout policy changes H1's natural box from 19 to 20 and H2's from 18 to 19. It is not a centring switch or a reliable correction based solely on `font.leading`.

**E-paragraph:** paragraph spacing is excluded from the caret. It can create space between stored paragraphs, but the wrapped paragraph runs at R, not P. Paragraph spacing is also not a substitute for spacing to the final extra line inside a paragraph.

**E-fixed-spacing:** capping the line height at R does not prevent the internal blank line's caret from including S. It reproduces B-calibrated's blank-line defect.

**E-typographic:** the public bounds were exactly natural-height and ink-centred; the actual typed insertion indicator was **(0,0,0,0)** and both native selection/insertion segments were absent. A trailing extra line sometimes consumed the proxy's bounds, while an internal blank caret could be assigned to the following line. The isolated empty document retained A's original height. This is not a usable layout engine. Do not adopt a getter-only proxy or infer native insertion behaviour from a `typographicBounds` printout.

**E-shell:** native margins transfer S of reserved trailing space above the first natural line. Merely adding top margin would increase the interval between separate paragraphs to P+S; the equal bottom transfer is essential. In the tested ordinary cases, glyph positions and P are preserved exactly, while the real native caret and selection use R. No glyph drawing override or segment-rectangle override is involved. Independent [white-ink pixel comparisons](round-d3/glyph-position-check.json) find zero changed pixels in all twelve typed/first/middle wrapped A-versus-E-shell pairs, excluding the narrow strip where the differently sized native stroke can occlude text.

## Empty and wrapped lines: the acceptance boundary

| Font | Variant | Caret (y,h) | Pitch before | Pitch after | Ink baseline | h−N | Room ink | Room x | Δtext |
|---|---|---|---|---|---|---|---|---|---|
| body | A-fixed | (34.500, 18.500) | 18.500 | 18.500 | 50.000 | 3.778 | 6.329 | 5.920 | 0.000 |
| body | B-spacing | (31.000, 18.778) | 15.000 | 18.778 | 43.000 | 4.057 | -0.949 | -1.358 | -7.000 |
| body | B-calibrated | (31.000, 18.500) | 15.000 | 18.500 | 43.000 | 3.778 | -0.671 | -1.080 | -7.000 |
| body | C-baseline | (32.974, 16.974) | 16.974 | 16.974 | 46.948 | 2.252 | 4.803 | 4.395 | -3.052 |
| body | D-multiple | (34.850, 18.850) | 18.850 | 18.850 | 50.700 | 4.128 | 6.679 | 6.270 | 0.700 |
| body | E-no-leading | (31.000, 18.778) | 15.000 | 18.778 | 43.000 | 4.057 | -0.949 | -1.358 | -7.000 |
| body | E-paragraph | (34.778, 15.000) | 18.778 | 15.000 | 46.778 | 0.278 | 2.829 | 2.420 | -3.222 |
| body | E-fixed-spacing | (31.000, 18.500) | 15.000 | 18.500 | 43.000 | 3.778 | -0.671 | -1.080 | -7.000 |
| body | E-typographic | (58.054, 14.722) | 18.500 | 18.500 | 50.000 | 0.000 | -37.000 | -37.409 | 0.000 |
| body | E-natural-baseline | (31.000, 18.500) | 15.000 | 18.500 | 43.000 | 3.778 | -0.671 | -1.080 | -7.000 |
| body | E-hybrid | (34.500, 15.000) | 18.500 | 15.000 | 46.500 | 0.278 | 2.829 | 2.420 | -3.500 |
| body | E-before | (34.500, 15.000) | 18.500 | 15.000 | 46.500 | 0.278 | 2.829 | 2.420 | -3.500 |
| body | E-shell | (34.500, 18.500) | 15.000 | 18.500 | 46.500 | 3.778 | -0.671 | -1.080 | -3.500 |
| body | F-default | (31.000, 15.000) | 15.000 | 15.000 | 43.000 | 0.278 | 2.829 | 2.420 | -7.000 |
| h1 | A-fixed | (37.000, 21.000) | 21.000 | 21.000 | 55.000 | 1.567 | 6.855 | 6.162 | 0.000 |
| h1 | B-spacing | (35.000, 20.567) | 19.000 | 20.567 | 51.000 | 1.135 | 3.287 | 2.594 | -4.000 |
| h1 | B-calibrated | (35.000, 21.000) | 19.000 | 21.000 | 51.000 | 1.567 | 2.855 | 2.162 | -4.000 |
| h1 | C-baseline | (35.736, 19.736) | 19.736 | 19.736 | 52.472 | 0.303 | 5.591 | 4.898 | -2.528 |
| h1 | D-multiple | (36.532, 20.532) | 20.532 | 20.532 | 54.065 | 1.100 | 6.387 | 5.694 | -0.935 |
| h1 | E-no-leading | (36.000, 21.567) | 20.000 | 21.567 | 52.000 | 2.135 | 2.287 | 1.594 | -3.000 |
| h1 | E-paragraph | (36.567, 19.000) | 20.567 | 19.000 | 52.567 | -0.433 | 4.855 | 4.162 | -2.433 |
| h1 | E-fixed-spacing | (35.000, 21.000) | 19.000 | 21.000 | 51.000 | 1.567 | 2.855 | 2.162 | -4.000 |
| h1 | E-typographic | (62.211, 19.433) | 21.000 | 21.000 | 55.000 | 0.000 | -42.000 | -42.693 | 0.000 |
| h1 | E-natural-baseline | (35.000, 21.000) | 19.000 | 21.000 | 51.000 | 1.567 | 2.855 | 2.162 | -4.000 |
| h1 | E-hybrid | (37.000, 19.000) | 21.000 | 19.000 | 53.000 | -0.433 | 4.855 | 4.162 | -2.000 |
| h1 | E-before | (37.000, 19.000) | 21.000 | 19.000 | 53.000 | -0.433 | 4.855 | 4.162 | -2.000 |
| h1 | E-shell | (37.000, 21.000) | 19.000 | 21.000 | 53.000 | 1.567 | 2.855 | 2.162 | -2.000 |
| h1 | F-default | (35.000, 19.000) | 19.000 | 19.000 | 51.000 | -0.433 | 4.855 | 4.162 | -4.000 |
| h2 | A-fixed | (36.000, 20.000) | 20.000 | 20.000 | 53.000 | 2.334 | 6.595 | 5.965 | 0.000 |
| h2 | B-spacing | (34.000, 20.334) | 18.000 | 20.334 | 49.000 | 2.668 | 2.261 | 1.631 | -4.000 |
| h2 | B-calibrated | (34.000, 20.000) | 18.000 | 20.000 | 49.000 | 2.334 | 2.595 | 1.965 | -4.000 |
| h2 | C-baseline | (34.669, 18.669) | 18.669 | 18.669 | 50.338 | 1.003 | 5.264 | 4.634 | -2.662 |
| h2 | D-multiple | (36.378, 20.378) | 20.378 | 20.378 | 53.756 | 2.712 | 6.973 | 6.343 | 0.756 |
| h2 | E-no-leading | (35.000, 21.334) | 19.000 | 21.334 | 50.000 | 3.668 | 1.261 | 0.631 | -3.000 |
| h2 | E-paragraph | (36.334, 18.000) | 20.334 | 18.000 | 51.334 | 0.334 | 4.595 | 3.965 | -1.666 |
| h2 | E-fixed-spacing | (34.000, 20.000) | 18.000 | 20.000 | 49.000 | 2.334 | 2.595 | 1.965 | -4.000 |
| h2 | E-typographic | (60.465, 17.666) | 20.000 | 20.000 | 53.000 | 0.000 | -40.000 | -40.630 | 0.000 |
| h2 | E-natural-baseline | (34.000, 20.000) | 18.000 | 20.000 | 49.000 | 2.334 | 2.595 | 1.965 | -4.000 |
| h2 | E-hybrid | (36.000, 18.000) | 20.000 | 18.000 | 51.000 | 0.334 | 4.595 | 3.965 | -2.000 |
| h2 | E-before | (36.000, 18.000) | 20.000 | 18.000 | 51.000 | 0.334 | 4.595 | 3.965 | -2.000 |
| h2 | E-shell | (36.000, 20.000) | 18.000 | 20.000 | 51.000 | 2.334 | 2.595 | 1.965 | -2.000 |
| h2 | F-default | (34.000, 18.000) | 18.000 | 18.000 | 49.000 | 0.334 | 4.595 | 3.965 | -4.000 |
| h3 | A-fixed | (34.500, 18.500) | 18.500 | 18.500 | 50.000 | 2.601 | 5.836 | 5.269 | 0.000 |
| h3 | B-spacing | (32.000, 18.601) | 16.000 | 18.601 | 45.000 | 2.701 | 0.735 | 0.168 | -5.000 |
| h3 | B-calibrated | (32.000, 18.500) | 16.000 | 18.500 | 45.000 | 2.601 | 0.836 | 0.269 | -5.000 |
| h3 | C-baseline | (33.352, 17.352) | 17.352 | 17.352 | 47.704 | 1.453 | 4.688 | 4.121 | -2.296 |
| h3 | D-multiple | (34.617, 18.617) | 18.617 | 18.617 | 50.234 | 2.718 | 5.953 | 5.386 | 0.234 |
| h3 | E-no-leading | (32.000, 18.601) | 16.000 | 18.601 | 45.000 | 2.701 | 0.735 | 0.168 | -5.000 |
| h3 | E-paragraph | (34.601, 16.000) | 18.601 | 16.000 | 47.601 | 0.101 | 3.336 | 2.769 | -2.399 |
| h3 | E-fixed-spacing | (32.000, 18.500) | 16.000 | 18.500 | 45.000 | 2.601 | 0.836 | 0.269 | -5.000 |
| h3 | E-typographic | (57.218, 15.899) | 18.500 | 18.500 | 50.000 | 0.000 | -37.000 | -37.567 | 0.000 |
| h3 | E-natural-baseline | (32.000, 18.500) | 16.000 | 18.500 | 45.000 | 2.601 | 0.836 | 0.269 | -5.000 |
| h3 | E-hybrid | (34.500, 16.000) | 18.500 | 16.000 | 47.500 | 0.101 | 3.336 | 2.769 | -2.500 |
| h3 | E-before | (34.500, 16.000) | 18.500 | 16.000 | 47.500 | 0.101 | 3.336 | 2.769 | -2.500 |
| h3 | E-shell | (34.500, 18.500) | 16.000 | 18.500 | 47.500 | 2.601 | 0.836 | 0.269 | -2.500 |
| h3 | F-default | (32.000, 16.000) | 16.000 | 16.000 | 45.000 | 0.101 | 3.336 | 2.769 | -5.000 |

These internal-blank values are **not** the isolated empty editor or a normal empty tail after typed text. E-shell gives R-height carets and zero glyph-baseline displacement from A for **both** of those ordinary empty cases. It also keeps the first and middle wrapped glyph baselines exactly at A and their interval exactly P. This is why an empty-after-title-only harness could falsely look complete.

The counterexample is already small: `"\n\n"`. For Body, B-calibrated's line baselines are **28, 43, 61.5**; A's are **31.5, 50, 68.5**. Its internal blank caret includes S and is 18.5 tall. E-shell restores the first baseline to 31.5, but subsequent baselines are **46.5, 65**: the first interval is still 15 and the internal caret is still 18.5 tall. E-hybrid/E-before give R-height blank carets and baselines **28, 46.5, 61.5**: the short interval moves to the extra tail instead of disappearing. Requested pending-tail spacing does not make these layouts stable merely by setting initial typing attributes.

Thus a blank-paragraph special case based only on `lineSpacing = 0` and moving S to paragraph spacing is **not a verified fix**. Returning, deleting the last character, changing selection and reopening must resolve the same geometry before the hint or first character is presented. D2's last-separator display attributes and extra-line ownership are directly relevant; their ordering must be tested in the fix round, not masked with a hint offset. No working public-input recipe for every blank-line topology was established here.

The per-fixture absolute frames and all wrapped displacements for A–F are in the full table. [Typed](round-d3/comparison-typed.png), [internal blank](round-d3/comparison-empty.png), [wrapped-middle](round-d3/comparison-wrapped-middle.png) and [selection](round-d3/comparison-selection.png) contact sheets are crops of actual cached native-view renders. The native stroke stays 2 pt wide; shortening it to R changes proportions without inventing a thinner stroke.

### First and middle wrapped-line frames

Room and height differences match the typed rows for each valid homogeneous-font variant; absolute band coordinates and selection frames remain in the complete CSV. INVALID proxy frames are rejection evidence.

| Font | Variant | First caret (y,h) | Middle caret (y,h) | First pitch | Middle pitch | First Δtext | Middle Δtext |
|---|---|---|---|---|---|---|---|
| body | A-fixed | (16.000, 18.500) | (53.000, 18.500) | 18.500 | 18.500 | 0.000 | 0.000 |
| body | B-spacing | (16.000, 15.000) | (53.557, 15.000) | 18.778 | 18.778 | -3.500 | -2.943 |
| body | B-calibrated | (16.000, 15.000) | (53.000, 15.000) | 18.500 | 18.500 | -3.500 | -3.500 |
| body | C-baseline | (16.000, 16.974) | (49.948, 16.974) | 16.974 | 16.974 | -1.526 | -4.578 |
| body | D-multiple | (16.000, 18.850) | (53.700, 18.850) | 18.850 | 18.850 | 0.350 | 1.049 |
| body | E-no-leading | (16.000, 15.000) | (53.557, 15.000) | 18.778 | 18.778 | -3.500 | -2.943 |
| body | E-paragraph | (16.000, 15.000) | (46.000, 15.000) | 15.000 | 15.000 | -3.500 | -10.500 |
| body | E-fixed-spacing | (16.000, 15.000) | (53.000, 15.000) | 18.500 | 18.500 | -3.500 | -3.500 |
| body | E-typographic | (0.000, 0.000) | (0.000, 0.000) | 18.500 | 18.500 | 0.000 | 0.000 |
| body | E-natural-baseline | (16.000, 15.000) | (53.000, 15.000) | 18.500 | 18.500 | -3.500 | -3.500 |
| body | E-hybrid | (16.000, 15.000) | (53.000, 15.000) | 18.500 | 18.500 | -3.500 | -3.500 |
| body | E-before | (16.000, 15.000) | (53.000, 15.000) | 18.500 | 18.500 | -3.500 | -3.500 |
| body | E-shell | (19.500, 15.000) | (56.500, 15.000) | 18.500 | 18.500 | 0.000 | 0.000 |
| body | F-default | (16.000, 15.000) | (46.000, 15.000) | 15.000 | 15.000 | -3.500 | -10.500 |
| h1 | A-fixed | (16.000, 21.000) | (58.000, 21.000) | 21.000 | 21.000 | 0.000 | 0.000 |
| h1 | B-spacing | (16.000, 19.000) | (57.135, 19.000) | 20.567 | 20.567 | -2.000 | -2.865 |
| h1 | B-calibrated | (16.000, 19.000) | (58.000, 19.000) | 21.000 | 21.000 | -2.000 | -2.000 |
| h1 | C-baseline | (16.000, 19.736) | (55.472, 19.736) | 19.736 | 19.736 | -1.264 | -3.792 |
| h1 | D-multiple | (16.000, 20.532) | (57.065, 20.532) | 20.532 | 20.532 | -0.468 | -1.403 |
| h1 | E-no-leading | (16.000, 20.000) | (59.135, 20.000) | 21.567 | 21.567 | -2.000 | -0.865 |
| h1 | E-paragraph | (16.000, 19.000) | (54.000, 19.000) | 19.000 | 19.000 | -2.000 | -6.000 |
| h1 | E-fixed-spacing | (16.000, 19.000) | (58.000, 19.000) | 21.000 | 21.000 | -2.000 | -2.000 |
| h1 | E-typographic | (0.000, 0.000) | (0.000, 0.000) | 21.000 | 21.000 | 0.000 | 0.000 |
| h1 | E-natural-baseline | (16.000, 19.000) | (58.000, 19.000) | 21.000 | 21.000 | -2.000 | -2.000 |
| h1 | E-hybrid | (16.000, 19.000) | (58.000, 19.000) | 21.000 | 21.000 | -2.000 | -2.000 |
| h1 | E-before | (16.000, 19.000) | (58.000, 19.000) | 21.000 | 21.000 | -2.000 | -2.000 |
| h1 | E-shell | (18.000, 19.000) | (60.000, 19.000) | 21.000 | 21.000 | 0.000 | 0.000 |
| h1 | F-default | (16.000, 19.000) | (54.000, 19.000) | 19.000 | 19.000 | -2.000 | -6.000 |
| h2 | A-fixed | (16.000, 20.000) | (56.000, 20.000) | 20.000 | 20.000 | 0.000 | 0.000 |
| h2 | B-spacing | (16.000, 18.000) | (56.668, 18.000) | 20.334 | 20.334 | -2.000 | -1.332 |
| h2 | B-calibrated | (16.000, 18.000) | (56.000, 18.000) | 20.000 | 20.000 | -2.000 | -2.000 |
| h2 | C-baseline | (16.000, 18.669) | (53.338, 18.669) | 18.669 | 18.669 | -1.331 | -3.993 |
| h2 | D-multiple | (16.000, 20.378) | (56.756, 20.378) | 20.378 | 20.378 | 0.378 | 1.134 |
| h2 | E-no-leading | (16.000, 19.000) | (58.668, 19.000) | 21.334 | 21.334 | -2.000 | 0.668 |
| h2 | E-paragraph | (16.000, 18.000) | (52.000, 18.000) | 18.000 | 18.000 | -2.000 | -6.000 |
| h2 | E-fixed-spacing | (16.000, 18.000) | (56.000, 18.000) | 20.000 | 20.000 | -2.000 | -2.000 |
| h2 | E-typographic | (0.000, 0.000) | (0.000, 0.000) | 20.000 | 20.000 | 0.000 | 0.000 |
| h2 | E-natural-baseline | (16.000, 18.000) | (56.000, 18.000) | 20.000 | 20.000 | -2.000 | -2.000 |
| h2 | E-hybrid | (16.000, 18.000) | (56.000, 18.000) | 20.000 | 20.000 | -2.000 | -2.000 |
| h2 | E-before | (16.000, 18.000) | (56.000, 18.000) | 20.000 | 20.000 | -2.000 | -2.000 |
| h2 | E-shell | (18.000, 18.000) | (58.000, 18.000) | 20.000 | 20.000 | 0.000 | 0.000 |
| h2 | F-default | (16.000, 18.000) | (52.000, 18.000) | 18.000 | 18.000 | -2.000 | -6.000 |
| h3 | A-fixed | (16.000, 18.500) | (53.000, 18.500) | 18.500 | 18.500 | 0.000 | 0.000 |
| h3 | B-spacing | (16.000, 16.000) | (53.201, 16.000) | 18.601 | 18.601 | -2.500 | -2.299 |
| h3 | B-calibrated | (16.000, 16.000) | (53.000, 16.000) | 18.500 | 18.500 | -2.500 | -2.500 |
| h3 | C-baseline | (16.000, 17.352) | (50.704, 17.352) | 17.352 | 17.352 | -1.148 | -3.444 |
| h3 | D-multiple | (16.000, 18.617) | (53.234, 18.617) | 18.617 | 18.617 | 0.117 | 0.351 |
| h3 | E-no-leading | (16.000, 16.000) | (53.201, 16.000) | 18.601 | 18.601 | -2.500 | -2.299 |
| h3 | E-paragraph | (16.000, 16.000) | (48.000, 16.000) | 16.000 | 16.000 | -2.500 | -7.500 |
| h3 | E-fixed-spacing | (16.000, 16.000) | (53.000, 16.000) | 18.500 | 18.500 | -2.500 | -2.500 |
| h3 | E-typographic | (0.000, 0.000) | (0.000, 0.000) | 18.500 | 18.500 | 0.000 | 0.000 |
| h3 | E-natural-baseline | (16.000, 16.000) | (53.000, 16.000) | 18.500 | 18.500 | -2.500 | -2.500 |
| h3 | E-hybrid | (16.000, 16.000) | (53.000, 16.000) | 18.500 | 18.500 | -2.500 | -2.500 |
| h3 | E-before | (16.000, 16.000) | (53.000, 16.000) | 18.500 | 18.500 | -2.500 | -2.500 |
| h3 | E-shell | (18.500, 16.000) | (55.500, 16.000) | 18.500 | 18.500 | 0.000 | 0.000 |
| h3 | F-default | (16.000, 16.000) | (48.000, 16.000) | 16.000 | 16.000 | -2.500 | -7.500 |

## Centring: what can actually be promised

| Font | Native h | h−N | Room natural | Room ink | Room x | h minus ink-band height |
|---|---|---|---|---|---|---|
| body | 15.000 | 0.278 | -0.448 | 2.829 | 2.420 | 3.556 |
| h1 | 19.000 | -0.433 | 0.528 | 4.855 | 4.162 | 3.894 |
| h2 | 18.000 | 0.334 | 0.662 | 4.595 | 3.965 | 4.267 |
| h3 | 16.000 | 0.101 | -0.204 | 3.336 | 2.769 | 3.640 |

E-shell's caret centres are within **0.332 pt** of the natural font-band centres for Body/H1/H2/H3; the reference has the same relative geometry. That meets approximate **typographic** centring and natural height. It does **not** prove optical centring on the ink: the native caret centres remain 1.415 / 2.427 / 2.298 / 1.668 pt above the cap-to-descender band centres. The x-height-band differences are separately recorded; lowercase-only lines do not magically share the cap-band centre.

A native caret is also 3.556 / 3.894 / 4.267 / 3.640 pt taller than these fonts' cap-to-descender bands. Consequently F-03 interpreted literally as “no taller than visible letters” is incompatible with simply adopting this native natural-height reference. No scalar paragraph setting measured here gives zero ink-room difference, natural height, all required pitches and unchanged glyph placement together. This is a measured limitation, not a new owner decision. Do not repeat D2's implication that stock equality alone resolves the owner's complaint.

## Exact integration budget for the recommended base

These are **design changes for E-shell's passing ordinary cases**, not implemented changes or proof for mixed content/blank interiors. Keep the existing R14 virtual line envelopes and block-gap rules. Do not zero `NoteTextStyle.baselineShift` globally: it currently influences paragraph gaps, decoration placement and table text origins, and the goal here is to keep the existing glyph baselines.

| Role | P | R | S transferred bottom → top |
|---|---:|---:|---:|
| Title | 22 | 22 | 0 |
| H1 | 21 | 19 | 2 |
| H2 | 20 | 18 | 2 |
| H3 | 18.5 | 16 | 2.5 |
| H4–H6 | 18.5 | 15 | 3.5 |
| Body, quote, list, callout, table text/header | 18.5 | 15 | 3.5 |
| Mono code text | 16.5 | 13 | 3.5 |

1. **Main text layout:** remove fixed min/max; use the measured default R and `lineSpacing = S`. For an ordinary paragraph add S to its native fragment top margin and subtract S from its bottom margin. This is a relocation of the existing line-leading budget, not extra paragraph space. It preserves typed and wrapped visual baselines; no extra glyph translation is needed. Negative plain-paragraph bottom margins were accepted by this OS in this test. Treat that behaviour as an OS compatibility gate. Existing contextual paragraph spacing stays part of the budget; do not stack another S in `paragraphSpacingBefore`.

2. **Callout:** the current physical fragment margins are `8 − 1.5258789 = 6.4741211` above and `8 + 1.5258789 = 9.5258789` below. The E-shell layout-margin equivalents are **9.9741211 above / 6.0258789 below**. The semantic painted padding remains 8/8, the box's outer edges and icon cap-height alignment remain unchanged when glyph baselines/tiling stay unchanged. Keep the icon following the actual baseline; add **no icon y offset**. `boxSlice`'s `exitsAtEnd` path computes a painted end from the last line's typographic bottom, so keep its existing painted bottom padding; do not blindly replace every bottom-padding value with the reduced layout margin.

3. **Code box:** Mono's existing shift is 2.0927734. The label row remains 14 with its 4 pt gap, and the semantic padding remains 8. Physical top margin changes from **23.9072266 to 27.4072266**; physical bottom margin from **10.0927734 to 6.5927734**. Keep the language label and copy button at their existing box-relative coordinates. No text, box, label or copy-button visual offset is intended. Inline code chips continue to follow their own glyph baselines; their mixed-font line-height risk remains below.

4. **Empty last-line boxes:** `lastLineBoxRect` is computed from a **line rect**, unlike the full-fragment box. On a passing empty tail, the natural line top moves down S and its bottom stays at A. To preserve the painted box, its top inset must therefore grow by S and its existing painted bottom inset must remain unchanged. Do not apply the full-fragment bottom-margin subtraction to this line-rect formula as well. Pending callout/code insets, O18-02 terminal-cap ownership and O18-04 exit spacing must be updated together. This formula does not solve the measured internal-blank topology.

5. **Quote bars, list markers and checkboxes:** zero additional visual offset in passing cases. Their baselines stay unchanged. Quote bar endpoints calculated from actual first/last baselines remain valid; joins that extend to fragment boundaries must continue using the unchanged virtual envelope. A missing blank-line interval must be repaired in layout, not by stretching a bar over it.

6. **Slash hint:** desired baseline displacement is **0**, because the recommended margin transfer preserves the real Body glyph baseline. Remove its dependence on `NoteCaretFitter.line`; obtain the TextKit baseline from the owning real fragment and align the hint's measured first text baseline to it. The current SwiftUI hint mixes a 12 pt Mono slash with 12.5 pt Body and rounds its hosting frame to integral points; those are not measured baseline APIs. Do not prescribe a guessed ±3.5 pt hint correction. If B-calibrated were used without the margin transfer, its required baseline movement would instead be **−3.5 pt**, exactly like Body text. A headless stock measurement cannot establish the current hint host's exact baseline error; that baseline must be instrumented in the fix round.

7. **Title placeholder:** S is **0** at the real 18.5 pt bold title font. Its 22 pt default line and fixed line have the same baseline in this run. No new title-placeholder y correction is indicated; draw it on the actual empty-title baseline rather than depending on an unrelated line-box centre. Its existing container-origin drawing and invalidation rect still need integration verification. Title/body/tag gaps remain unchanged by this geometry design.

8. **Table cells:** table Body and semibold header both have R=15 and S=3.5. The live cell currently has a stock layout manager; it needs the same top/bottom margin transfer if its existing editor frame is retained. The inactive cell is drawn separately by `NSAttributedString.draw(with:)` and has no such fragment delegate: move its drawing origin **down 3.5 pt** and reduce the drawing rect's available height by 3.5 to retain its lower edge. Keep the grid's virtual `count × 18.5` row measurement, padding, borders and row origins. An alternative using a shared +3.5 cell-text origin must account for that transfer in the live editor's used height as well; do not change only the live editor or only the static renderer. No change to the current cell's outer padding or column widths is intended. Actual U+2028 cell breaks and editor/static parity were not exercised here; the numeric font budget is measured, the table integration is source-derived.

9. **Selection:** accept native R-height highlights for passing text lines. E-shell moves their top down S relative to A and retains their bottom. There is **no separate highlight offset** to retain the former full-pitch highlight: that would restore the same caret/selection mismatch by another route. Internal blank highlights still include S in the failing case. Marquee/object selection visibility remains a separate responsibility; preserve D2's visibility-only requirements when removing fitting.

10. **After tables, images and attachments:** remove the fitter's special geometry substitution only with explicit native boundary tests. A native tall attachment line is legitimately a different layout input. Do not apply the ordinary-font R budget to an attachment line or derive its insertion position from the table's last row.

## TextKit 2 mechanism and risks

Across every valid non-proxy row, the actual indicator's x/y/height equals the public **standard zero-length text segment** to floating-point precision (maximum difference under 1e−14 pt). Its height also follows the relevant real line box. This is evidence about current AppKit's observable result, not reverse engineering or a promise that its private implementation simply reads one getter. The broken proxy is the counterexample to such a promise.

Apple documents [line spacing](https://developer.apple.com/documentation/appkit/nsparagraphstyle/linespacing), [line-fragment typographic bounds](https://developer.apple.com/documentation/appkit/nstextlinefragment/typographicbounds), native fragment [top margins](https://developer.apple.com/documentation/appkit/nstextlayoutfragment/topmargin) and [font-leading policy](https://developer.apple.com/documentation/appkit/nstextlayoutmanager/usesfontleading). The installed SDK headers were also inspected. Bounds/line-fragment arrays are read-only properties; fragment margins are genuine paragraph layout inputs. Rendering attributes are applied **before layout**, so a rendering `.baselineOffset` is not a documented way to move ink independently while freezing native geometry. No public API inspected promises a separately configurable native indicator height or optical centre.

| Risk | Finding / fix-round requirement |
|---|---|
| Wrapping | Homogeneous first/middle wrapped pitch and placement are measured. Preserve line breaks, word wrapping, hyphenation, bidi, width changes, long paragraphs and viewport reuse in the integrated editor. Paragraph-only spacing fails soft wraps. |
| Blank lines | The internal-blank counterexample remains. Test leading blanks, several Returns, final extra lines after a blank, U+2028, deleting the last glyph, moving selection away/back, reopen and Undo/Redo. Require stable baselines and native caret height before accepting E-shell globally. |
| Selection height | R-height selection is measured and deliberately differs from A. Test ranges crossing styles, paragraph separators, attachment lines, Find and marquee. Do not make native caret geometry depend on a separately stretched highlight. |
| Mixed fonts | B/E-shell remove a maximum-height cap. Larger pasted fonts, bold/italic fallback, inline Mono, superscripts, emoji and font fallback can enlarge a line naturally. A scalar S derived from the paragraph's base font cannot guarantee P for those lines. This round measures homogeneous fonts only; decide whether natural expansion or enforced pitch wins, and measure both before promising parity. |
| Attachments/images | Natural attachment ascent/descent may exceed P and should not be clipped or assigned the base-font budget. Test insertion before/after images, inline attachments, files, tables, plus empty tails and object selection. Not measured by the scalar matrix. |
| IME marked text | Marked text can introduce fonts, baseline offsets, underlines and intermediate paragraph states. Do not normalize away marked attributes or reflow from transient typing attributes. Check composition/commit/cancel, candidate anchoring, reconversion, hint suppression, dictation and Emoji & Symbols in the fix round. No live IME/input-source test was performed. |
| OS/scales | Negative margin transfer and font-rounding behaviour need macOS 26 and 27 checks, at 1x and 2x. The public insertion anchor's zero width must not be used to invent a stroke width. This run covers one OS and 2x only. |
| Decorations/document bounds | Font geometry cannot repair D2's missing final callout extent, terminal cap or contextual exit normalization. Carry those fixes separately while keeping padding ownership consistent with the numeric budget above. |

## Verification and disposition

- `Scripts/xcodebuild_locked.sh build-for-testing`: **passed**, Local/`ATTIC_LOCAL_ONLY`, own `.build/dd-d3`, manual ad-hoc signing and the isolated identities above.
- Final `.build/d3-verified.xcresult`: **25 tests passed, zero failures/skips**. Two D3 measurement tests, three existing passing D2 causal controls, five `PhaseXCaretTests`, fifteen `RoundO3NotesTests`. The five known red D2 product regressions are unchanged and were deliberately not included in this passing measurement run.
- Project regenerated from `Scripts/generate_project.rb`; `Scripts/verify_project_generation.rb` **passed**. Semantic comparison confirms every target's build settings are unchanged and the sole added source is the D3 test; the larger generated diff is identifier regeneration.
- Original cached renders and four comparison sheets inspected headlessly; no screen capture or product app launch. The report's block, hint and table changes are a **source-derived integration design**, not a rendered integrated prototype.
- An exploratory measurement-helper cast crashed one earlier run; corrected before the final run. Experimental proxy segment failures remain explicitly recorded as rejection evidence, not hidden by a passing test count. Earlier exploratory bundles are not the final evidence.
- [Reproduction commands and artifact guide](round-d3/README.md); [test summary](round-d3/test-summary.json); [outcome](round-d3/test-outcome.txt). Hindsight tools were not exposed; no Hindsight facts were used. No product implementation, merge, deployment or CI dispatch.

The fix round has a measured ordinary-line geometry and exact integration budget. It still needs a working blank-line layout and an explicit acceptance of native typographic centring versus exact ink centring. This round establishes those limits instead of shipping a fourth unverified caret adjustment.
