# Devin handoff: hover and pinned subtask windows

## Assignment and exact baseline

Implement this feature fully in the existing native macOS Attic application, not
a web mockup. Use SWE-2 with Max effort. Continue through appropriate validation,
then report actual results and remaining macOS UAT. Do not stop at a plan.

Repository: https://github.com/TesterPen0812/Attic.git

Assigned branch: `codex/attic-hover-pinned-subtasks`.
Snapshot commit: `df57e7c66fffe7e8fe988a7bc080563b22bcae61`.
Its parent is `b109b17634f2e1626903b98f6fd381fea4b1ed3d`.
The handoff document and visual references are a subsequent commit on the same
branch. Fetch that branch and start from its handoff commit, not main or the old
parent. Verify the snapshot is an ancestor before editing.

The snapshot contains all 24 previously uncommitted subtask, compact-composer,
MCP hardening, test and documentation files. It was captured using a temporary
Git index; all 185 source file hashes matched. The original checkout, its index,
and its dirty status were verified unchanged. It is the user's backup and is
outside your write scope. The separate local snapshot worktree is
`/Users/taha/Developer/attic-hover-pinned-subtasks`; cloud execution cannot assume
this path exists. Create/use an isolated cloud worktree on the assigned branch.
Do not modify any other branch or repository. Do not merge, deploy, install over
Attic Daily, or force-push. Commit implementation on the assigned branch and
push that branch only so the user can retrieve the result. Do not open a PR or
change shared configuration without a separate request.

## Final UX, superseding earlier alternatives

The user reviewed a planning conversation titled Spreadsheet Alternatives Table
(the title is misleading). The final decision is a transient hover panel that
can become an independent pinned mini-window. The earlier bottom drawer and
inline accordion are superseded; do NOT implement both alternatives.

Visual reference: `Docs/References/hover-pinned-subtasks-concept.png` is the final
selected concept. `Docs/References/current-attic-before-hover.png` shows the
actual app before this change. Inspect both, then reuse the repository's existing
glass, squircle, typography, themes, spacing and native controls. The concept's
sample content is illustrative, never hard-code it into production. The concept
shows an X; the transient design uses a pin button instead, as specified below.
No global redesign, replacement visual language, or decorative mobile handle.

1. Main task rows remain compact: checkbox, title, inline `2/4` progress where
   children exist, and ellipsis actions. Remove disclosure up/down/chevron
   controls and the old expanded inline child list. No permanent second progress
   line when the inline count fits; preserve readable long-title layout.
2. Hovering a family row for about 300–400 ms opens a floating panel beside it,
   about 260–310 points wide. Brief pointer crossings must not open it. It has the
   parent title, progress, compact child checklist, and `+ Add subtask`.
3. Pointer travel across the gap from row to panel keeps it alive. Moving inside
   the panel must not dismiss it. Leaving both surfaces dismisses after a short
   grace period. Pending opens/closes are cancellable when the hovered family
   changes or disappears. Menus, text entry, and focus within the auxiliary
   surface must not fight auto-hide or lose drafts.
4. The transient surface is anchored to the row, follows main-panel movement,
   and has no Dock presence. Clamp/flip to the available display bounds. Handle
   main-list scrolling, filtering and row removal without stale anchors or
   dangling windows. Do not leave an unrelated transient surface on main hide.
5. The top-right pin action promotes the same shared subtask UI into a genuine
   draggable persistent mini-window. Pinned lifecycle is independent: main
   Attic may hide/close its panel, change focus, and reopen without destroying
   the pinned checklist. Child checkboxes and editing continue to work there.
   Closing the main panel is NOT quitting the app.
6. Pinning leaves the main Attic panel open. This is the conservative default
   chosen for the planning chat's unresolved final question. The user can use
   normal hide behavior afterward. Do not auto-hide it as a side effect of pin.
7. Pinned windows remember their last screen position; restore/clamp safely if
   displays change. Expose accessible unpin and close behavior without confusing
   pin state with task completion. Unpin returns to transient behavior if a valid
   visible anchor exists, otherwise dismisses; it never deletes any task.
   Automatic reopening of pinned content after full app quit was not finalized;
   do not invent complex session restoration beyond position memory.
8. Version one supports one pinned family at a time. Do not silently replace it
   merely by hovering another row. If pinning a different family, resolve the
   old pinned window and draft safely and make replacement explicit. Keep the
   controller architecture amenable to multiple families later without building
   multi-pin now. A transient preview for another family may coexist with the
   one pinned window, with no duplicate window for the same family.
9. Provide a click/keyboard/VoiceOver alternative to hover for opening the same
   family panel. Checkbox only changes status; ellipsis only opens actions.
   Audit the existing task-row double-click/start behavior so the new fallback
   does not cause accidental state changes or swallow established actions.
10. Clicking a child checkbox updates progress everywhere immediately after a
    successful durable save. Completed children stay in stable positions, muted
    and struck through. Finishing all children does not auto-complete the parent.
    Preserve current explicit parent-completion and reopening guards.
11. `+ Add subtask` opens inline entry; Enter saves, Escape cancels. Keep drafts
    scoped to their parent and safe through pin/unpin, focus and main hide.
    Preserve existing edit/delete/priority operations through real controls;
    use existing editing conventions (the chat did not settle single-click title
    editing versus selection). Display save errors; do not discard failed edits.
12. Zero-child tasks do not spawn empty hover panels. Their actions menu must
    still offer Add subtask and open focused entry. Handle deletion of the last
    child and deletion of an open/pinned parent without invalid model references.
13. Adaptive height for short lists, bounded scrolling for long lists; only the
    auxiliary child list scrolls, with title/actions stable. Keep compact usable
    pointer targets and meaningful accessibility labels/state. Respect reduced
    motion and reduced transparency using existing patterns.

Keep the compact main composer already in this snapshot. The earlier instruction
to replace/hide it applied to an in-panel bottom drawer and is superseded by the
separate-window design. Do not needlessly hide the main composer when an auxiliary
window is open; the contexts are now visually separate. Preserve its typed title,
priority strip and draft behavior. No other speculative feature additions.

## Code and safety constraints

Read root AGENTS.md and claude.md first. Preserve their macOS-first, local-first
development contract verbatim. Existing architecture includes:

- `Attic/Views/Panel/TaskFamilyView.swift`, `TaskRowView.swift`,
  `TaskSectionView.swift`, and `AtticPanelView.swift` for current inline families.
- `Attic/Window/PanelUIState.swift` for drafts/focus/auto-hide interaction locks;
  inspect the rest of `Attic/Window` and `Attic/App/AppCoordinator.swift` for panel
  movement, hide/show, activation, lifecycle, presentation and fresh contexts.
- `Attic/Models/TaskItem.swift` and `Attic/Services/TaskStore.swift`: optional
  scalar parentID, one-level families, durable rollback, duplicate-safe physical
  replica mutations/deletion and local-day cleanup guards. Reuse these APIs,
  do not replace the data model for a presentation change.
- Existing task actions and `AtticStyle` provide shared controls and visuals.
- `AtticTests/SubtaskTests.swift`, `AppSettingsTests.swift`,
  `AgentServerIntegrationTests.swift`, and `AtticUITests/AtticUITests.swift`.

Keep secure MCP credentials, lazy opt-in/background loading, cancellation and
listener-generation guards intact. Never read/copy real client credentials,
Keychain exports, user containers or production stores into cloud or fixtures.
Don't enable CloudKit/APNs/iPhone or claim deferred functionality works.
Compile normal macOS development with ATTIC_LOCAL_ONLY and sandbox/network-only
entitlements. Official bundle is com.taha.Attic; team ZGZWS73268 unless locally
overridden. Native preview must have unique display/executable/bundle identity
and isolated local store. No Daily replacement, migration, deletion, credential
permission weakening, or system-authentication bypass.

## Verification and delivery

Inspect existing changes first, make the smallest coherent implementation,
add behavior-oriented lifecycle/state tests and update now-obsolete inline
disclosure UI tests. Do not weaken assertions or equate tests with visual proof.

Read README testing instructions and Scripts before invoking commands. After
adding project inputs regenerate with `bundle exec ruby Scripts/generate_project.rb`
and run `bundle exec ruby Scripts/verify_project_generation.rb`. Run relevant
unit tests and the macOS target build using the repo's local-only configuration.
Run relevant script tests; preserve real official-SDK MCP regression coverage.

`Docs/SubtasksComposerValidation-2026-09-09.md` records historical baseline
evidence: 582 unit tests passed on macOS, while full subtask XCTest UI validation
was not complete due to hit-testing and subsequent OS automation authorization.
Those are NOT test results for your new implementation. Evidence bundles in the
local ignored .build directory are not included in the cloud branch.

The currently selected cloud environment may be Ubuntu. If Xcode/AppKit/SwiftData
or signing is unavailable, perform all meaningful available static/script tests,
add the native tests, and clearly mark native build/test/UI checks UNRUN because
of environment. Do not remove platform imports or fake a web implementation to
produce a pass. Do not request a different project scope to work around this.

Native acceptance checklist (automate where meaningful, report residual UAT):
hover dwell; row-to-panel gap traversal; rapid row changes; text/menu focus;
pin/unpin; main hide and reopen; moving main vs moving pinned; outside focus;
position persistence and multi-monitor bounds; empty/large families; long titles;
child create/edit/complete/delete; parent deletion while open; failed-save rollback;
fresh-context replacement; no stale/doubled windows or leaked event monitors;
keyboard/VoiceOver and reduced-motion behavior; compact composer unchanged.

Before final handoff inspect the diff, commit and push only the assigned branch.
Report exact final SHA, files/behavior changed, commands and actual outcomes,
screenshots if a genuine native preview was available, preview provenance, and
remaining macOS validation. Never claim production/release readiness. Leave the
original local worktree and installed Daily app as the user's backups.
