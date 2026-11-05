# Fix round 7 — 5 November 2026

Branch: phase-3/pd-fix7; base: 62be8dcc. Each implementation commit pushed to origin.

- UX-1 — Already fine. The UX audit's own continuation (ux-audit-2.md, “Correction — withdraw”) confirms the click missed the result; a verified click opened the note. The report withdraws this finding. No change or artificial red test; existing NotesLibraryRow button calls onOpen and NotesPageController.openFromLibrary opens the note.
- UX-2 — Fixed, 389a6684. Settings adaptive content respects the available viewport, preventing clipped controls and sideways shifting in the default window.
- SW-02 — Fixed, e55d9019. Unrelated task revisions skip Notes metadata database fetches.
- SW-01 — Fixed, 1d322bd7. Thumbnail cache evicts least-recently-used images individually and preserves a visible row's image.
- UX-3 — Fixed, 38c86134. Closed Draw library menu is removed from the accessibility hierarchy; no shared dropdown cause was demonstrated.
- UX-4 — Part done (source investigation only). NoteFormatControls.swift places suggestions directly above the selection bar and adjusts TextKit fragment room. Keeping the pin/••• unobstructed for first-line selections requires deciding where this combined bar and suggestion stack should move. Left for the owner under the brief's explicit layout-decision exception; no speculative redesign.
- SW-03 — Fixed, 696f6956. Deleted-note body summaries and writing-known identities are pruned against the live inventory independently of count.
- SW-04 — Fixed, b3a93417. Arrow navigation reuses an ordered-ID/index snapshot until row inventory, folding or layout changes; list rows skip unchanged preparation. Frame-time improvement not measured.
- SW-05 — Fixed, 8a017ff2. Date-chip images use a 64-entry recency cache, invalidated on appearance changes. Regression first failed at 73 cached images, then passed. Memory savings not measured.

Verification: SettingsWindowHostedTests 4 passed; Notes metadata focused tests passed; NotesLibraryRowsDesignTests 8 passed for SW-01 and 9 passed for SW-04; DrawLibraryTests 16 passed; NotesLibraryOrganizeTests 19 passed; NoteEditorEngineTests 180 executed, 3 skipped, 0 failed. Final ad-hoc-signed Local macOS app build succeeded. No screen, preview, Air, CI, or VoiceOver UAT was run under the worktree rules.

Files outside findings: this report only. Open: UX-4 needs owner layout direction and on-screen validation; UX-2/UX-3 require owner visual/accessibility UAT. Deferred dated-task move, helper copy, search excerpts and Ideas untouched.
