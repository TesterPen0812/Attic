# Direct Sol implementation — Notes inline-anchor reliability and PERF-A3

Date: 2026-09-14
Checkout: `/Users/taha/Developer/attic-task-panels-v2`
Branch/HEAD: `codex/attic-task-panels-v2` / `ae6418c1af690e29d15a20344cdb9765a23d3f85`

## Outcome

Implemented the bounded fixes requested by the two independent Luna reviews in
`Docs/Direct-Luna-Correctness.md` and `Docs/Direct-Luna-Regression.md`.

- Editor-originated saves now carry a validated ordered edit batch through
  `NoteDraftController.flush()` into `NoteStore.update`. This preserves the
  physical occurrence of repeated identical paragraphs because the save path
  no longer has to infer the edit location from old/new text.
- `NSTextView` proposed edits are captured before `NSTextStorage` coalesces a
  grouped transaction into one union callback. Replacement strings are retained
  and replayed against the exact prior body; the proposed batch is accepted only
  when that replay exactly produces the new UTF-16 body. Otherwise the ledger
  conservatively uses the storage callback/fallback path.
- Body/batch/cache comparisons that affect anchor movement now compare exact
  UTF-16 code units. Paragraph differences also compare UTF-16 arrays, so
  decomposed and precomposed canonical equivalents with different lengths are
  no longer treated as unchanged.
- The draft owns the ledger across SwiftUI re-evaluations. A new editor session
  re-anchors it; same-session external replacement invalidates it; successful
  saves consume/reset it; failed saves retain it for retry.
- The existing PERF-A3 hoist remains: a body-only save derives at most one
  paragraph edit list, outside the attachment loop. Editor saves supply the
  exact list and derive none. `attachmentAnchorFallbackDerivations` is the
  focused diagnostic seam.

The body-only fallback remains deterministic and paragraph-bounded, but cannot
infer the physical identity of identical paragraph occurrences. That ambiguity
is unavoidable without an edit history and remains limited to non-editor
callers that do not supply `bodyEditBatch`.

## Owned source and test changes

- `Attic/Models/NoteInlineAnchor.swift`
- `Attic/Views/Panel/NoteInlineCards.swift`
- `Attic/Views/Panel/NoteAttachmentTray.swift`
- `Attic/Services/NoteStore.swift`
- `Attic/Services/NoteDraftController.swift`
- `Attic/Views/Panel/NotesPanelContent.swift`
- `AtticTests/NoteInlineCardsTests.swift`
- `AtticTests/NoteDraftControllerTests.swift`
- this report

Focused coverage now includes canonical Unicode normalization, native grouped
`NSTextStorage` transactions with pre-coalescing edit capture, duplicate
paragraph persistence, two physical attachment replicas, failed-save rollback
and exact-batch retry, undo, editor-session switching, remote-body adoption, and
the one-derivation diagnostic bound.

## Verification

Build, using a distinct DerivedData directory and without launching an app:

```sh
xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic \
  -configuration Local -derivedDataPath /tmp/attic-direct-sol-fix-dd \
  -only-testing:AtticTests CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO
```

Result: `TEST BUILD SUCCEEDED`. Only existing deprecation, unreachable-code,
ad-hoc-signing, and AppIntents metadata warnings appeared.

Focused Notes run through the established offline XCTest host:

```text
NoteInlineCardsTests NoteInlineCardsPerformanceTests NoteStoreTests
NoteDraftControllerTests NoteAttachmentTests
126 tests, 0 failures
```

Integration run adds the no-subpanel-swipe and panel geometry/performance gates:

```text
PanelSurfaceHostingViewTests SubtaskPanelControllerTests PanelGeometryTests
TaskPerformanceGateTests plus the five Notes suites above
273 tests, 2 skips, 0 failures
```

The skips are the existing environment-gated physical gesture cases. Logs are
`/tmp/attic-offline-xctest/direct-sol-fix-report-final.log` and
`/tmp/attic-offline-xctest/direct-sol-fix-final-integration.log`.

`git diff --check` is clean. The existing preview process at
`/tmp/attic-chrome-checkpoint-dd/Build/Products/Local/AtticChromeCheckpoint.app`
was not rebuilt, relaunched, or used.

## Final source hashes

```text
4264bbe8dc2f9ebb2c9f8cad77534c77cf4ee7d3189f5706158885a0b75d127d  Attic/Models/NoteInlineAnchor.swift
c4536ee2ac22ca0c6fdc3a1cc46cf2742eb0a85e2f906b4a77374bf30c78b09d  Attic/Views/Panel/NoteInlineCards.swift
ac270a4f1c165cebf9b7d184923ec9ece645ca415168c116c9b77c65086f4f6d  Attic/Views/Panel/NoteAttachmentTray.swift
0936d8a0a3850ab96b1a7c9e4e80843e9a4e9a0a0df6445b8b1b9afda3a0e17a  Attic/Services/NoteStore.swift
53cd6296c949d5fe86a8b0c904099e2a2eff54ffcd90f1635180b802e1c171d2  Attic/Services/NoteDraftController.swift
d9606e2acae7d14fc64a1a519d427a285567b354c2b22a9b1c2c181cef71f37f  Attic/Views/Panel/NotesPanelContent.swift
a07e71b6a576d7c2a5bccf847a5023c597f1193cbd96a09136a6d6f5fbf70103  AtticTests/NoteInlineCardsTests.swift
b2892c16bdeaf699c876fa4c6a49286026e26197fc7602f327115c8f4964be0f  AtticTests/NoteDraftControllerTests.swift
```

## Limits

No app launch, live editor input, visual, gesture, accessibility, CloudKit,
iPhone, TestFlight, production, profiling, or performance magnitude is claimed.
Canvas PERF-A1 was inspected but not edited in this bounded Notes fix.

IMPLEMENTATION_READY_FOR_REREVIEW
