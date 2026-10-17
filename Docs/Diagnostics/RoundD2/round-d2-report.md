# Round D2 — callout bounds, empty-line spacing, and native caret diagnosis

**Diagnosis only; product code is unchanged.** Branch `phase-x/d2`, starting at int13 `b07795e41a9cb44326b4614202ad9bfc85696dc7`. Tests, measurements and 81 headless renders are committed in **`3c171522`**. All five regression tests remain red for the combined fix round.

The clipping is real: the final callout needs 9.51 pt more document height. Return preserves the next line but drops the callout's final 9.53 pt of padding and its bottom rounding. Reopening a note loses the same 9.53 pt between the callout and its empty Body line. The caret is AppKit's indicator, subsequently shortened and moved by Attic. The grey bar in the supplied heading/quote example is a quote decoration, reproducible with exactly one insertion indicator.

## Scope, method and verification

- Inspected all six supplied images, `owner-1017b/shot-59.png` through `shot-64.png`, plus the owner-feedback and O3 reports. In the supplied files, shot-62 contains the `gjgj…` plain-text line; shot-63 contains the `Khkj` heading and the grey bar beside the following line.
- No screen input, screen captures, app activation, ordered windows, owner app launches, or owner containers/preferences/data. D2's host is `com.taha.Attic.preview.d2.unithost`; its activation policy is `prohibited`. The application bundle override is `com.taha.Attic.preview.d2`, never an owner identity.
- Tests use unshown windows at (-9000, -9000). A test-only window subclass reports `isKeyWindow` and `isMainWindow` as true; it never calls `makeKey`, `orderFront`, or activation APIs. This allows an ordinary stock TextKit 2 `NSTextView` to create its **own real `NSTextInsertionIndicator`**. Indicators are read by recursively traversing subviews and converting their public `frame` into text-view coordinates. No substitute indicator is inserted by D2.
- macOS **27.0 (26A5425a)**, SDK 27.0, arm64; bitmaps are 2x. Public APIs checked in the installed SDK's `NSTextView.h` and `NSTextInsertionIndicator.h` (the indicator API is available from macOS 14). This is not validation on every supported OS.
- All builds used `Scripts/xcodebuild_locked.sh`, `.build/dd-d2`, Local configuration, and the exact requested signing flags. `build-for-testing` passed. The app source is compiled in the isolated macOS unit host; no standalone application build/launch was needed for diagnosis.
- Regenerated `Attic.xcodeproj`; `Scripts/verify_project_generation.rb` passes. Only the generated project, new tests and diagnosis artifacts changed. `git diff b07795e4 -- Attic AtticMobile Scripts` is empty.
- Final run: **28 tests, 23 pass, five fail, zero skips**. D2 has eight tests: five red regression cases (27 assertion failures) and three passing causal controls. Existing **PhaseXCaretTests: 5/5 pass; RoundO3NotesTests: 15/15 pass**. Test command exits 65 intentionally. No CI was dispatched.
- Final xcresult: `.build/d2-evidence.xcresult`. Committed evidence is `Docs/Diagnostics/RoundD2/`: `measurements.json`, `stock-vs-ours.csv`, `pixel-measurements.json`, `test-summary.json`, `test-outcome.txt`, `render-manifest.json`, and `renders/`. Exact rerun commands are in its README. Assets are also copied beside this report under `round-d2/`.
- Hindsight tools were not exposed in this session; no claims from Hindsight were used. The two specified local toolchain/attachment notes were read directly. No subagents were used.

## O18-01 — final callout is clipped

**Root cause.** `Attic/Notes/Engine/NoteEditorTextView.swift:489` corrects the document frame only through `trailingMonoBlockBottom()`. `Attic/Notes/Engine/NoteBlockLayout.swift:903` explicitly accepts only `noteBlockStyle == "mono"`. Callouts and O3's empty-last-line callout decoration are excluded. AppKit sizes the text view to the text line's end, omitting the decoration's trailing margin.

The callout geometry itself is present: `NoteBlockLayout.swift:94` and `:97` provide top/bottom margins; `:112` builds a box slice; `:129` exposes the callout box; `:144` computes the first-line icon slot. O3's empty picked box is computed at `:194`. `renderingSurfaceBounds` already unions the decoration at `:304`; enlarging that surface alone cannot enlarge its enclosing text view.

**Measured evidence.** With actual host-style `textContainerInset.height = 0`, the final typed callout has:

| Measurement | Points |
|---|---:|
| Box top / bottom | 32.0083 / 66.5083 |
| Last text line bottom | 56.9824 |
| Required bottom margin | 9.5259 |
| Document bounds bottom | 57.0000 |
| Decoration outside document | **9.5083** |
| Short test viewport bottom | 55.0000 |

The text container's height is effectively unbounded (`CGFloat.greatestFiniteMagnitude`), so its maximum height is not the limiting constraint. The document is too short even if the viewport is scrolled. The empty picked callout also ends at 66.5083 while its document ends at 57.0000.

**Red tests (evidence commit `3c171522`, `phase-x/d2`):**

- `RoundD2DiagnosisTests.testO1801FinalCalloutDecorationFitsDocumentBounds`
- `RoundD2DiagnosisTests.testO1801EmptyPickedCalloutDecorationFitsDocumentBounds`

**Renders:** `round-d2/renders/o18-01-final-typed-callout-document.png` versus `o18-01-final-typed-callout-full-fragment.png`; and `o18-01-empty-picked-document.png` versus `o18-01-empty-picked-full-fragment.png`. The full-fragment render has the intact rounded bottom and icon; the actual document render truncates them. These are cached off-screen bitmaps, not screen captures.

**O3 attribution.** The typed-callout height omission predates O3 (`e1fda0501`, 10-08). O3 adds a newly visible empty-box path without extending the existing height correction, so that new path also clips. It exposes the existing document-sizing assumption.

**Smallest fix plan.** Generalize the existing guarded trailing-block height calculation to the final painted block, including callout slices and a box owned by the preceding paragraph's empty last line. Use the decoration's actual bottom in text-view coordinates and keep the existing reentrancy protection. Do not change the page's footer inset to hide this error. Preserve native resizing/shrinking and viewport-driven layout.

**Risks/checks.** Avoid size/layout recursion, accumulating extra height, or a full-document scan on each keystroke. Check short and scrollable notes, empty picked boxes, long/wrapped boxes, resize, Undo/Redo, code/table/image tails, and the bottom edge after scrolling fully down.

## O18-02 — Return leaves the empty continuation flush with a square bottom

**Root cause.** `NoteBlockLayout.swift:694` treats a pending same-icon empty last line as continuing the box. That sets `ends: false` at `:673`. `bottomMargin` at `:100` consequently returns zero. However, `emptyLastLineDecoration` at `:1388` also returns nil for a continuation, because `startsEmptyLastLineBox` at `:1405` says it does not start a new box. Neither path owns the terminal padding/rounded bottom of this still-final visual run.

`boxSlice` at `:114` ends at the fragment's height, which here ends with the empty text line. `drawBox` at `:486` extends the rounded shape past a non-terminal slice and clips it to the slice: `ends: false` deliberately produces a square lower edge. Re-invalidating cannot invent the padding or terminal cap because these decisions repeat deterministically.

**Measured evidence after real `insertNewline(nil)`:**

| Measurement | Points |
|---|---:|
| Original single-line box bottom | 66.5083 |
| Continued box bottom | 83.4824 |
| Empty line fragment | y 64.9824, height 18.5000 |
| Empty line bottom | 83.4824 |
| Required padded bottom | **93.0083** |
| Missing terminal padding | **9.5259** |
| Document bounds bottom | 83.5000 |

The box does grow by 16.9741 pt, but loses its terminal padding and rounding. In this headless run the fitted blue caret ends about 0.24 pt inside the box's bottom, rather than physically below it; it has no breathing room. This precisely distinguishes the measured defect from the owner's description. The input and empty line are retained.

**Red test:** `RoundD2DiagnosisTests.testO1802ReturnContinuationBoxContainsEmptyLineAndPadding`, commit `3c171522`, branch `phase-x/d2`.

**Renders:** `round-d2/renders/o18-02-return-continuation-document.png`, `o18-02-return-continuation-viewport.png`, `o18-02-return-continuation-full-fragment.png`.

**O3 attribution.** The continuation/ends decision is unchanged from `8a16b6866` (10-14), before O3. The controlled pre-O3 content-delegate policy yields the same box bottom 83.4824 and empty-line y 64.9824. O3's separate empty-box renderer intentionally skips this continuation, so it does not repair it.

**Smallest fix plan.** Distinguish a following stored slice from an empty terminal line continuing this same visual box. The last slice must include that empty line, one terminal bottom padding, and the final rounded cap. Reserve those extents in layout and document sizing; invalidate the owning paragraph when its pending continuation changes. Do not draw a second overlapping box over the continuation.

**Risks/checks.** No doubled padding/seams in multi-paragraph or wrapped runs; different icons split runs; Return twice exits to Body; inserting in the middle still joins correctly; Undo/Redo, typing the first letter, and moving the caret away preserve the same geometry. Recheck equivalent code tails.

## O18-04 — empty Body spacing differs from typed Body spacing

**Root cause on reopen.** `NoteTextCodec.swift:29` builds initial paragraph attributes without the `monoExitsAtEnd` context, leaving the callout's paragraph spacing zero. `NoteEditorEngine.swift:448` restores the empty paragraph's semantic state, but does not apply the contextual restyle to the callout above it before presentation.

That contextual restyle **does** exist at `NoteEditorEngine.swift:873`. For a callout ending before the extra empty Body line it supplies `monoExitsAtEnd: true`; `NoteTextStyle.swift:329` transfers **8 + 1.5258789 = 9.5258789 pt** into `paragraphSpacing`. This is necessary because TextKit lays the empty line inside the preceding paragraph; when a real character is typed, Body becomes its own paragraph and the callout's normal bottom margin is used instead.

The slash hint does not independently allocate spacing: `NoteFormatControls.swift:1276` uses `firstRect(forCharacterRange:)`, then positions the SwiftUI hint at the selected line's baseline (`:1282`). Therefore it follows the incorrectly laid-out extra line. O3's pending-last-line display hook excludes Body at `NoteBlockLayout.swift:1365`, so it cannot supply this missing context.

**Measured evidence** for a reopened note with two callout paragraphs and an empty Body tail:

| State | Box bottom | Body line y | Gap from box to line box |
|---|---:|---:|---:|
| Empty, reopened | 93.0083 | 93.9565 | **0.9482** |
| First letter typed | 93.0083 | 103.4824 | **10.4741** |
| Existing contextual restyle, no typing | 93.0083 | 103.4824 | **10.4741** |

The first character moves the line **9.5259 pt down**. Calling only the existing `restyle` on the preceding callout restores exactly those 9.5259 pt, without changing any text or adding a placeholder offset. The passing causal control verifies it against an independently constructed typed reference. Before restyle, the callout's `paragraphSpacing` is 0; after it is 9.5259.

The empty hint host is `(24, 97, 205, 16)` in this case. Its glyph ink need not equal the line-box top: the supplied screenshot's exact overlap is not recreated from the unavailable original note. The near-zero **line-box** gap and first-letter spacing jump are reproduced and measured.

**Additional click-route timing defect.** With two callout paragraphs, `startLineBelowFinalBlock()` produces an 8.0000 pt empty-line gap, which changes to 10.4741 on typing. With one callout, the cached empty-line y is 82.9907; a pure fresh layout with the **same** content delegate changes it to 76.9824. `setPendingParagraphStyle` (`NoteEditorEngine.swift:3720`) invalidates/restyles and refreshes before assigning final typing attributes at `:3735`. The empty line can therefore be laid out using a transient style. This is a lifecycle ordering issue in addition to the reopened-note context omission.

**Red test:** `RoundD2DiagnosisTests.testO1804EmptyBodyAfterCalloutDoesNotJumpWhenTypingStarts`, commit `3c171522`, branch `phase-x/d2`. Its below-click and reopen routes fail; double Return and explicitly picking Body already pass in the two-paragraph fixture.

**Passing controls:** `testO1804ContextualRestyleRestoresLoadedExitPaddingWithoutTyping`; `testPreO3CalloutDisplayPolicyStillHasTheContinuationAndBodyGapDefects`.

**Renders:** `round-d2/renders/o18-04-reopen-empty-document.png`, `o18-04-reopen-typed.png`, `o18-04-restyled-without-typing-document.png`, and the `o18-04-below-click-*` pair.

**O3 attribution.** Reopened spacing is an older codec/restyle mismatch. The freshly laid-out current and pre-O3 display policies give the same reopened line y (67.4565 in the one-callout control). The old `ensureBodyAfterFinalBlock()` helper also remains unchanged. O3 newly routes below-block clicks to it and adds refresh calls before final typing-attribute assignment, exposing the timing-sensitive click case. The policy experiment is not an older-binary run; it isolates the relevant delegate behavior and is backed by the source diff/history.

**Smallest fix plan.** Once the trailing empty paragraph's semantic state is restored, normalize its preceding box's contextual exit spacing before initial layout. Finalize pending state and typing attributes before the final owning-paragraph invalidation on edit/click routes. Use that same layout for the hint and the first character. A fixed hint margin would only mask the mismatch.

**Risks/checks.** Keep presentation-only normalization out of Undo and durable content. Test reopen, fresh editor attachment, leaving/re-entering the line, click below, Return twice, explicit Body selection, first character, Undo/Redo, width changes, both icon variants, and one/many callout paragraphs. Check code blocks, which use the same exit-spacing machinery.

## O18-03 — complete caret customization inventory

| Location | Customization and effect |
|---|---|
| `NoteEditorTextView.swift:52` | Overrides `shouldDrawInsertionPoint` to suppress the legacy insertion point during marquee selection. No `drawInsertionPoint` override exists in Notes. |
| `NoteEditorTextView.swift:656`, `:658`, `:663`, `:807` | Owns `NoteCaretFitter`; refreshes it after native insertion-point timer updates, selection changes and layout. |
| `NoteTableCellEditor.swift:397`, `:399`, `:404`, `:409` | The same fitter and update/selection/layout hooks in table-cell text views. |
| `NoteMarqueeSelection.swift:147` | Refreshes the fitter as block selection changes. |
| `NoteCaretFit.swift:39`, `:142`, `:215` | Recursively finds system `NSTextInsertionIndicator` subviews (skipping content subtrees), watches frame notifications, and refits whenever AppKit places one. |
| `NoteCaretFit.swift:61`, `:79`, `:89` | Replaces native height with cap height + measured `p`/`y` ink descent + two 3.5%-of-font-size margins. This is a custom glyph-ink oracle, not native line geometry. |
| `NoteCaretFit.swift:105`, `:129`, `:138` | Guesses the line from the indicator midpoint, gets font from typing attributes, and snaps the baseline to the lower device pixel. The existing fitter, not AppKit, then chooses y/height. |
| `NoteCaretFit.swift:155`, `:196`, `:203` | Mutates the indicator's actual frame; special-cases tall attachment lines and shortens a caret after a table to the last row. Preserves x/width. |
| `NoteCaretFit.swift:158` | Hides/restores modern indicator display modes during marquee selection. This visibility behavior is separate from fitting. |
| `NoteEditorEngine.swift:743`, `:811`; `NoteTableCellEditor.swift:95`; `NoteTextStyle.swift:182` | Sets insertion-point color to the system `.textInsertionPointColor`. No custom blue, width, blink timing, replacement caret view, or replacement caret layer is created in Notes. |
| `NoteCalloutIconSession.swift:54` | Its separate emoji-input receiver uses a **clear** insertion point and clear text, so the note's icon is not duplicated. It exists only while choosing an icon. |
| `NoteTextStyle.swift:295`, `:414`, `:440`; `AtticComponentTokens.swift:633` | Fixed paragraph line heights, contextual paragraph spacing, indents and table-cell attributes influence AppKit's rect. H1 21 pt, H2 20, H3–H6/body/quote/list/callout 18.5; H4–H6 share the small-heading role. Title is 22. No Notes `.baselineOffset` styling was found. |
| `NoteBlockLayout.swift:91`, `:97`, `:564`; `NoteEditorEngine.swift:1365`, `:2027`, `:3716` | Custom fragment margins and O3's separator-display/typing attributes influence real line placement. Pending styles include empty-box top padding. These are layout inputs, distinct from the fitter's output mutation. |
| `NoteEditorTextView.swift:839`, `:864` | Draws the empty title placeholder with an attributed string at the container origin, without drawing a caret. |
| `NoteFormatControls.swift:1271`; `NoteFormatViews.swift:1181` | Separate SwiftUI slash hint; places its host using the selection rect, fitter's baseline lookup, an ascender estimate and `.integral` rounding. It neither creates nor draws an insertion indicator. |

The selection-highlight hiding hooks (`NoteEditorTextView.swift:92`) affect `_NSTextSelectionView` opacity for selected objects, not caret width or a second caret.

### Stock versus ours: actual AppKit indicator frames

The stock view uses the same attributed fonts, fixed line heights, paragraph spacing and indents, with Attic's display transformation for list markers/headings replicated. It has no custom block fragments and no fitter. A callout's custom top margin therefore moves its absolute baseline in ours; the baseline-relative columns isolate caret fitting from that intentional block padding. Every row has **one native indicator in stock and one in ours**.

Frames below are `(y, height)` in text-view points. Full x/bottom/width values and font metrics are in `measurements.json` and `stock-vs-ours.csv`.

| Line | Font pt | Stock (y, h) | Ours (y, h) | Stock top − baseline | Ours top − baseline |
|---|---:|---:|---:|---:|---:|
| body | 12.5 | (30.482, 18.500) | (36.755, 11.990) | -15.500 | -9.227 |
| h1 | 16.5 | (30.744, 21.000) | (36.797, 15.899) | -18.000 | -11.947 |
| h2 | 15.0 | (30.677, 20.000) | (36.906, 14.453) | -17.000 | -10.771 |
| h3 | 13.5 | (30.860, 18.500) | (36.516, 13.008) | -15.500 | -9.845 |
| h4 | 12.5 | (30.482, 18.500) | (36.755, 12.044) | -15.500 | -9.227 |
| h5 | 12.5 | (30.482, 18.500) | (36.755, 12.044) | -15.500 | -9.227 |
| h6 | 12.5 | (30.482, 18.500) | (36.755, 12.044) | -15.500 | -9.227 |
| callout | 12.5 | (32.008, 18.500) | (44.755, 11.990) | -15.500 | -9.227 |
| list | 12.5 | (30.482, 18.500) | (36.755, 11.990) | -15.500 | -9.227 |
| quote | 12.5 | (30.482, 18.500) | (36.755, 11.990) | -15.500 | -9.227 |
| empty-placeholder | 12.5 | (30.482, 18.500) | (36.755, 11.990) | -15.500 | -9.227 |

Body/placeholder fitting cuts **6.5105 pt** off the native 18.5 pt indicator and moves its top **6.2727 pt down**. Its center is **3.0175 pt lower** than native. H1 is shortened by 5.1013 pt; its center is 3.5019 pt lower than native. These are measured mutations, not estimates from screenshots. The extra pixel snapping contributes about 0.018 pt for Body and 0.256 pt for H1 in this fixture.

AppKit reports a zero-width public indicator frame in these runs; that is normal for its insertion-position anchor. Independent PNG pixel measurement shows the visible blue stroke is **4 pixels / 2 pt in both stock and ours**, for Body and H1. There is no doubled stroke in ours and no extra horizontal displacement. Shortening the height while preserving that native stroke makes its proportions heavier.

**Root cause of divergence:** `NoteCaretFit.swift:188` substitutes glyph-ink metrics and `:196` writes those over the system frame, including on future frame-change notifications. Tests based on stand-in indicators never established that this matched current AppKit. `PhaseXCaretTests.swift:93` creates its own indicator and asserts the fitter's chosen formula; those five tests pass while the real-native comparison fails.

**Red test:** `RoundD2DiagnosisTests.testO1803RealNativeIndicatorsMatchStockRelativeToLineBaseline`, commit `3c171522`, branch `phase-x/d2` (height and baseline-relative placement fail for all 11 rows).

**Against the supplied images:**

- **Shot-61, placeholder:** the hint is drawn by SwiftUI separately from the caret and rounded independently to an integral host frame. In the reopened headless fixture the blue stroke is at pixel rows 201–223; it is short and follows the misplaced empty line. The comparison proves the fitter shortens/moves it; it does **not** prove that it is physically higher than stock. In fact it is lower than stock. Do not add another compensating y offset to satisfy an unmeasured “too high” interpretation. Native proportions and baseline-aligned hint drawing need the Air's screen confirmation.
- **Shot-62, plain text / shot-63, heading:** the native stroke width is unchanged; shortening produces the heavier appearance. H1's top is 6.053 pt lower relative to its baseline than native, while the stroke remains 2 pt. The renders reproduce the compact blue bar adjacent to the heading. Any actual horizontal offset beyond the native half-stroke at the insertion anchor is not reproduced.
- **Shot-63, grey bar:** `NoteBlockLayout.swift:265` computes the quote bar; `:344` draws it. The `heading-then-quote` control has exactly one blue indicator on the heading and a separate **3 × 11.0574 pt** grey quote bar on the next line, whose text is indented **20 pt**. The `heading-then-body` control keeps the same single blue indicator and removes the grey bar and indent. This matches the supplied image's 6-pixel bar and 40-pixel text offset at 2x. It is a quote decoration in the matching reproduction, not a stale second insertion indicator or a dictation/emoji effect. The historical note's semantic attributes were not read from owner data; attribution of that exact past note is necessarily based on the matching geometry/render.

**Renders:** `round-d2/renders/o18-03-{body,h1,h2,h3,h4,h5,h6,empty-placeholder,callout,list,quote}-{stock,ours}.png`, plus `o18-03-heading-then-quote.png` and `o18-03-heading-then-body.png`. Passing control: `testO1803GreyBarBelowHeadingIsQuoteDecorationWithOneIndicator`.

### Fix plan: use AppKit's caret

1. Remove geometry fitting from both main-editor and table-cell timer, selection and layout hooks. Remove frame-observer rewriting, cap/`p`/`y` reach calculations, device-baseline snapping and the after-table height substitution. Let AppKit own indicator frame, width, color, blink and effects from the actual TextKit line. The stock control demonstrates the native height and center for every requested text style.
2. Preserve the system insertion-point color. Preserve the narrowly needed marquee visibility suppression: `shouldDrawInsertionPoint` alone does not hide the modern indicator subview. If a visibility observer is retained, it must only hide/restore public display modes, never rewrite geometry. Preserve the clear caret in the temporary icon-input receiver.
3. Keep layout inputs correct first: fix callout terminal extents and empty Body exit spacing. Align the hint's **measured first text baseline** to the real TextKit line baseline, with no dependency on caret-fitting metrics or an arbitrary hint margin. Check the title placeholder similarly; avoid assuming its natural SwiftUI/attributed-string height equals the fixed line height.
4. Replace the existing geometry-oracle tests in the combined fix round with real stock-versus-editor indicator comparisons. Keep meaningful observer/visibility lifecycle tests as applicable. Do not make a shorter synthetic indicator the acceptance oracle again.

**Risks.** Native carets are taller and, in these measurements, extend farther above the text than the fitted ones. Removing fitting therefore deliberately restores native proportions; it is not a promise that a screenshot-based “too high” impression disappears. Table/attachment boundaries may show the native full-height caret where the old fitter shortened it. Establish the intended insertion location and line layout before considering any exception. Never retain a geometry override solely because the old self-referential tests expected it.

**Required checks for the combined fix:**

- Real indicator equality against stock, normalized to the real line baseline, for Body, H1–H6, empty Body after title/callout/code, callout, quote, list, and table-cell text; matching fonts and paragraph styles. Same x anchor and native stroke width; one indicator per insertion point.
- Blink restart, typing/deleting, selection/arrow movement, resize, scroll, editor detach/re-attach, note switch and Undo/Redo do not reinstate fitted/stale frames.
- Marquee hides native indicators and restores their prior public modes; range selection has no duplicate caret. Icon input, IME, dictation and Emoji & Symbols retain native effects/focus with no leaked receiver.
- Empty/typed hint baselines and block gaps agree before and after reopening, on both appearance modes and 1x/2x screens. Inspect the Air's actual screen result before accepting the owner-visible outcome.
- Final callout and Return continuation contain their last line plus full padding, have the proper bottom corners, are scrollable through their whole painted extent, and do not jump when the first character is typed.
- Run the affected Notes/formatting/Undo/table suites, project-generation gate and macOS build. Recheck typing cost if the extent/invalidation implementation changes layout work. No CloudKit, iPhone or production behavior is inferred from this diagnosis.

No fix, deployment, merge or CI run was performed. The five red tests and native comparison are ready for the combined fix round after the Air's checks.
