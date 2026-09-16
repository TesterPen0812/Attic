# Attic live visual-state catalog

Capture session: `2026-09-14T14:19:34+01:00` to `2026-09-14T14:46:24+01:00`

This catalog contains 63 PNG captures from the running Attic Chrome Checkpoint preview, including menus, submenus, popovers, native pickers, modal sheets, settings pages, and transient canvas instructions. `62` are usable window-specific captures; `TP-001-main-tasks-baseline.png` is retained but excluded because it was an accidental full-screen Codex capture rather than the Attic window.

Open [the browsable gallery](./index.html) for visual inspection.

## Provenance

- Source checkout: `/Users/taha/Developer/attic-task-panels-v2`
- Preview: `/tmp/attic-chrome-checkpoint-dd/Build/Products/Local/AtticChromeCheckpoint.app`
- Bundle identifier: `com.taha.Attic.chromecheckpoint`
- Git revision: `ae6418c1af690e29d15a20344cdb9765a23d3f85` (`Make pinned panel interactive and add real macOS XCUITest coverage`)
- Preview executable SHA-256: `af455672e248e83cee28b743189fc955b8c9e19887a5df34d7ead89600d19017`
- Preview CDHash: `5bdc556896891954649b04413620294cca6cfd6e`
- Captures were made against the live process using explicit window IDs. No source edits, build, relaunch, install, permission change, or release action was performed for this catalog.
- Existing catalog material was inspected first. The earlier `20260914T131431Z-attic-chrome-checkpoint-dd` folder was not overwritten.

## Fixture and privacy disclosure

The preview was already a QA-oriented local state. To reach otherwise unavailable states, the run left clearly marked disposable fixtures in the app:

- `[QA] Screenshot catalog note` with safe long text for autosave and scrolling.
- `[QA] Empty Canvas Catalog` with a rectangle, text, and two incidental ink strokes; it has four items in total. The incidental strokes were not deleted because destructive cleanup was outside capture scope.
- `[QA] Added from catalog`, a completed subtask under the existing `Chrome check — plan weekend` task; that parent now shows `1 of 9 complete`.
- `batch3-image.png` and `batch3-normal-file.txt` attached to the existing `Chrome check — plan weekend` task.
- `[QA] Screenshot catalog task with a deliberately long title for truncation coverage`, created with High priority and the two fixture attachments, then marked complete so the Done state could be captured. It remains in the preview.

The `NT-005-saved-notes-drawer.png` image visibly includes pre-existing saved-note content. It is kept local and is called out here so it is not mistaken for catalog fixture text. No personal content is reproduced in this index.

## Coverage and limits

Covered: pinned and unpinned Tasks, empty Backlog, task metadata, subtasks, partial completion warning, attachments and native task picker, composer focus/long title/priority/pending attachments, task context menu and nested Priority/Move-to menus, completed QA task, Notes empty/long/saved/scrolled/drawer/native picker, Canvas populated/empty/object selection/style/zoom/ink menus/document/actions menu and its View/Edit submenus/new-canvas sheet/shape palette/pending rectangle instruction, application menus, native Colors panel, and every Settings page.

Not confirmed: true pointer-hover-only dock expansion and hover-only row actions. The UI automation surface does not expose a reliable mouse-hover primitive, so those are listed as unvisited rather than inferred from keyboard focus. Tasks empty-state and a fully empty Notes state were not forced because doing so would require deleting or otherwise disturbing existing content.

The native picker captures are OS-level windows, so their dimensions and surrounding margins differ from the Attic panel captures. The task context-menu captures include the panel behind the menu; the nested submenu captures were made from the live menu windows. `TP-041-task-context-submenus.png` is a supplemental root-menu capture retained from the same interaction; the distinct nested states are `TP-042` and `TP-043`.

## State index

All times below are local London time during the single capture session. Provenance is `live preview / explicit window screenshot` unless noted otherwise. Steps describe the state immediately before capture; menus and sheets were dismissed after capture unless the fixture state was intentionally retained.

### Tasks and task panels

| State | Image | Reproduction and state | Limitations / notes |
|---|---|---|---|
| TP-001 | [baseline-window](./TP-001-main-tasks-baseline-window.png) | Open the pinned Tasks section at session start. | Correct Attic-window baseline. |
| TP-001-X | [baseline-excluded](./TP-001-main-tasks-baseline.png) | Accidental first screenshot before switching to the explicit Attic window ID. | Excluded: full-screen Codex capture. |
| TP-002 | [unpinned](./TP-002-main-tasks-unpinned.png) | Toggle the panel pin control and capture the unpinned panel state. | Window visibility is transient when unpinned. |
| TP-010 | [empty-backlog](./TP-010-backlog-empty-pinned.png) | Switch to Backlog with no backlog ideas and leave the panel pinned. | Existing task data was preserved. |
| TP-012 | [task metadata](./TP-012-main-task-attachment-subtask-metadata.png) | Return to Tasks and show `Chrome check — plan weekend` with attachment and subtask metadata. | Existing task used as visual fixture. |
| TP-013 | [completion warning](./TP-013-parent-completion-warning.png) | Attempt to complete the parent with unfinished subtasks; capture the warning sheet, then cancel. | No parent completion was committed. |
| TP-020 | [subtasks populated](./TP-020-subpanel-subtasks-populated.png) | Click the task row’s Show subtasks action. | Transient subpanel. |
| TP-021 | [subpanel pinned](./TP-021-subpanel-pinned.png) | Pin the task subpanel and capture its populated Subtasks mode. | Existing subtasks retained. |
| TP-022 | [subtask composer](./TP-022-subpanel-composer-empty.png) | Open Add subtask in the pinned subpanel without entering text. | Composer was dismissed. |
| TP-023 | [nine subtasks](./TP-023-subpanel-nine-subtasks.png) | Add `[QA] Added from catalog` to the fixture parent. | QA subtask intentionally retained and later marked done. |
| TP-024 | [attachments empty](./TP-024-subpanel-attachments-empty.png) | Switch the pinned subpanel to Attachments before adding fixture files. | Empty state only. |
| TP-025 | [native task picker](./TP-025-native-task-picker-fixture.png) | Open Add attachment and navigate to `.build/batch3-live/fixtures`. | Native picker includes the two disposable fixture files. |
| TP-026 | [one attachment](./TP-026-subpanel-attachment-image.png) | Attach `batch3-image.png`, then open the subpanel Attachments view. | QA fixture attachment. |
| TP-027 | [image and file](./TP-027-subpanel-attachments-image-file.png) | Attach `batch3-normal-file.txt` as well and recapture Attachments. | QA fixture attachments. |
| TP-028 | [partial completion](./TP-028-subpanel-partial-completion.png) | Mark the QA subtask done and return to Subtasks. | Parent remains incomplete at `1 of 9`. |
| TP-030 | [composer add menu](./TP-030-composer-add-menu.png) | Open the task composer Add menu. | Menu dismissed after capture. |
| TP-031 | [priority expanded](./TP-031-composer-priority-expanded.png) | Expand Task options in the composer to show None/Low/Medium/High. | No task submitted in this state. |
| TP-032 | [long title focused](./TP-032-composer-long-title-focused.png) | Focus the composer with the long QA title. | Draft state. |
| TP-033 | [High priority title](./TP-033-composer-high-priority-long-title.png) | Select High priority for the long QA draft. | Draft state. |
| TP-034 | [pending image](./TP-034-composer-pending-image.png) | Stage the disposable image in the composer. | Not yet submitted at capture time. |
| TP-035 | [pending image and file](./TP-035-composer-pending-image-file.png) | Stage both disposable attachments with the long title and High priority. | Captured before submission; the final fixture task was later submitted. |
| TP-040 | [task context menu](./TP-040-task-context-menu.png) | Secondary-click the existing fixture parent row. | Destructive Delete item was not selected. |
| TP-041 | [context-menu supplemental](./TP-041-task-context-submenus.png) | Supplemental capture from the same task context-menu interaction. | Root menu duplicate retained for provenance; see TP-042/043 for nested menus. |
| TP-042 | [Priority submenu](./TP-042-task-priority-submenu.png) | Open Priority from the task context menu. | Options were dismissed without changing the parent. |
| TP-043 | [Move-to submenu](./TP-043-task-move-to-submenu.png) | Open Move to from the task context menu. | Options were dismissed without moving the parent. |
| TP-044 | [composer options with attachments](./TP-044-composer-options-with-pending-attachments.png) | Reopen the composer Add menu while both fixture attachments were pending. | Menu dismissed. |
| TP-045 | [composer priority with attachments](./TP-045-composer-priority-dropdown-with-attachments.png) | Open Task options while the long title and both pending files were present. | High remained selected; menu dismissed. |
| TP-046 | [long-title task](./TP-046-main-long-title-task-added.png) | Submit the marked QA draft and capture the new High-priority task in progress. | Disposable task intentionally retained. |
| TP-047 | [completed task](./TP-047-main-completed-qa-task.png) | Click the QA task completion control and capture it under Done. | Disposable completed task intentionally retained. |

### Notes

| State | Image | Reproduction and state | Limitations / notes |
|---|---|---|---|
| NT-001 | [new empty note](./NT-001-new-note-empty.png) | Create a new note and capture before entering body text. | QA note fixture. |
| NT-002 | [long unsaved note](./NT-002-note-long-unsaved.png) | Enter long safe QA text before autosave settles. | QA note fixture. |
| NT-003 | [long saved note](./NT-003-note-long-saved.png) | Wait for the saved indicator. | QA note fixture. |
| NT-004 | [note bottom](./NT-004-note-long-scrolled-bottom.png) | Scroll the note body to its lower boundary. | Scroll position is intentional. |
| NT-005 | [Saved Notes drawer](./NT-005-saved-notes-drawer.png) | Open Saved notes from the Notes controls. | Includes pre-existing saved-note content; local-only. |
| NT-006 | [native picker quota warning](./NT-006-native-picker-quota-warning.png) | Open Attach files and capture the Documents picker showing the iCloud paused/quota/error presentation. | Native OS state; no file was selected. |

### Canvas

| State | Image | Reproduction and state | Limitations / notes |
|---|---|---|---|
| CV-001 | [populated Canvas](./CV-001-canvas-populated.png) | Open the existing Canvas section. | Existing Canvas is shown without editing it. |
| CV-002 | [empty QA Canvas](./CV-002-canvas-empty-qa.png) | Open `[QA] Empty Canvas Catalog` before placing objects. | QA Canvas fixture. |
| CV-003 | [shape menu](./CV-003-canvas-shape-menu.png) | Open Add Shape from the populated Canvas fixture. | Menu dismissed. |
| CV-004 | [rectangle selected](./CV-004-canvas-rectangle-selected.png) | Fit the QA Canvas and select its rectangle. | QA Canvas fixture. |
| CV-005 | [selected style menu](./CV-005-canvas-selected-style-menu.png) | Open object style controls with the rectangle selected. | Menu dismissed. |
| CV-006 | [text selected](./CV-006-canvas-text-selected.png) | Select `[QA] placed text`. | QA Canvas fixture. |
| CV-007 | [zoom menu](./CV-007-canvas-zoom-menu.png) | Open the Canvas zoom dropdown. | Menu dismissed. |
| CV-008 | [zoomed out](./CV-008-canvas-zoomed-out.png) | Choose Zoom Out. | QA Canvas fixture. |
| CV-009 | [mixed objects](./CV-009-canvas-mixed-objects.png) | Show the rectangle, QA text, and incidental ink strokes with no selection. | Four-item QA fixture; two strokes were incidental. |
| CV-010 | [ink style](./CV-010-canvas-ink-style-popover.png) | Open Ink and Width. | Popover dismissed. |
| CV-011 | [blue ink style](./CV-011-canvas-blue-style.png) | Select Blue in the ink style popover. | Style state is fixture-only. |
| CV-012 | [Canvas document menu](./CV-012-canvas-document-menu.png) | Open the Canvas document/actions menu. | Menu dismissed. |
| CV-013 | [New Canvas sheet](./CV-013-new-canvas-modal.png) | Open Canvas actions > New Canvas, type focus is visible, then cancel. | No additional Canvas was created. |
| CV-014 | [shape dropdown](./CV-014-canvas-shape-dropdown.png) | Open the Add Shape dropdown showing Rectangle/Ellipse/Line/Arrow. | Menu dismissed. |
| CV-015 | [pending rectangle instruction](./CV-015-canvas-pending-rectangle.png) | Choose Rectangle and capture the transient “Drag on the canvas to place a rectangle” state; switch back to Select Object without drawing. | Matches the supplied reference pattern. |
| CV-016 | [Canvas View submenu](./CV-016-canvas-view-submenu.png) | Open Canvas actions > View. | Fit Content and Reset View were not selected. |
| CV-017 | [Canvas Edit submenu](./CV-017-canvas-edit-submenu.png) | Open Canvas actions > Edit. | Clear Canvas was not selected. |

### Application menus and Settings

| State | Image | Reproduction and state | Limitations / notes |
|---|---|---|---|
| MENU-001 | [application menu](./MENU-001-application-menu.png) | Open the AtticChromeCheckpoint application menu. | Native macOS menu. |
| MENU-002 | [Edit menu](./MENU-002-edit-menu.png) | Open Edit from the menu bar. | Native macOS menu. |
| MENU-003 | [View menu](./MENU-003-view-menu.png) | Open View from the menu bar. | Native macOS menu. |
| MENU-004 | [Window menu](./MENU-004-window-menu.png) | Open Window from the menu bar. | Native macOS menu. |
| MENU-005 | [Help menu](./MENU-005-help-menu.png) | Open Help from the menu bar. | Native macOS menu. |
| SET-001 | [Appearance](./SET-001-settings-appearance.png) | Open Settings > Appearance. | Captures translucency, glass-style, palette, gradient, and radio controls in their current state. |
| SET-002 | [General](./SET-002-settings-general.png) | Open Settings > General. | Startup toggle left unchanged. |
| SET-003 | [Panel](./SET-003-settings-panel.png) | Open Settings > Panel. | Docking, timing, shape, and size controls left unchanged. |
| SET-004 | [Agent Access](./SET-004-settings-agent-access.png) | Open Settings > Agent Access. | Access remained off. |
| SET-005 | [About](./SET-005-settings-about.png) | Open Settings > About. | Repository link not opened. |
| SET-006 | [native Colors panel](./SET-006-native-colors-panel.png) | Capture the native Colors panel surfaced during the menu/palette interaction. | OS-level panel; no color change was committed. |

## Verification performed

- `63` PNG files were enumerated in this session directory.
- `file` verified all captures are readable PNGs and recorded their dimensions in the working log.
- The live preview bundle identifier, executable path, CDHash, SHA-256, and source revision were recorded above.
- The app remained launchable and navigable throughout capture. Two transient UI-automation stale-element/app-changed messages were re-queried successfully; they are noted as tooling limitations, not claimed app defects.
