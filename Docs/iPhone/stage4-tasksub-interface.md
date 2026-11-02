# Stage 4 — iPhone task steps and task writing

`@MainActor PhoneTaskSubtasks(container:now:save:)` owns local SwiftData
transactions for the task page. Construct it from the same registered
`ModelContainer` as `PhoneLibrary`. All reads use fresh contexts; writes use
one fresh context, one save, and rollback on failure. No `TaskItem` or
`NoteItem` reference escapes the API. Conflicting physical UUID replicas,
ambiguous ownership, and mixed live/deleted copies fail closed.

## Caller signatures

```swift
func subtasks(of parentID: UUID) throws -> [PhoneTaskSubtasks.Subtask]
func addSubtask(to parentID: UUID, title: String) throws -> PhoneTaskSubtasks.Subtask
func editSubtask(id: UUID, title: String) throws -> PhoneTaskSubtasks.Subtask
func toggleSubtask(id: UUID) throws -> PhoneTaskSubtasks.Subtask
func reorderSubtask(id: UUID, toIndex: Int) throws -> [PhoneTaskSubtasks.Subtask]
func deleteSubtask(id: UUID) throws

func loadTaskNote(taskID: UUID) throws -> PhoneTaskSubtasks.TaskNote?
func createTaskNoteIfNeeded(taskID: UUID, initialWriting: String = "") throws -> PhoneTaskSubtasks.TaskNote
```

`Subtask` contains `id`, `parentID`, `title`, `status`, `isDone`, `manualOrder`,
`createdAt`, `updatedAt`, and `completedAt`. The list puts open steps first,
then Done, with descending manual order and stable creation/UUID ties.
Creation appends to the unfinished group. Toggling moves to the top of its
new group; reopening is disallowed while the parent is Done. Reordering uses a
**zero-based index within the step's own open or Done group**; an out-of-range
index fails without changes. Deletion soft-hides the child and records a
single-member deletion group; it never deletes rows or note bytes.

`TaskNote` contains `id`, `taskID`, `title`, `body`, exact `content: Data?`,
`contentFormat`, `contentFingerprint`, `revision`, `revisionID`, `updatedAt`.
A missing note loads as nil without writing. Creating writing makes a native
`attic.note/1` document requiring `taskNote`, plus a `TaskNoteAssociation`
with matching task/note generations, in one save. Repeated creation returns
the existing note **without modifying or re-encoding its bytes** when no draft
is supplied. A nonempty `initialWriting` for an existing note is refused, so
new typing is not silently discarded; `initialWriting` is only used on creation. Unknown content and newer document formats remain
byte-identical. A task lifecycle deletion must preserve the note's stored
`content`, and must not cascade-delete its `NoteItem` or attachment payloads.
This service never deletes notes or modifies task-note content after creation.

## Integration for the lead

- **Task page / PhoneDetails:** use `subtasks(of:)` to render the compact step
  list and route add/edit/toggle/reorder/delete gestures through these methods.
  Refresh the parent page and task rows after successful mutations. The
  existing `PhoneLibrary.tasks()` returns roots **and** children; a top-level
  Tasks list needs to filter `parentID == nil`.
- **Writing area:** call `loadTaskNote(taskID:)` on open and
  `createTaskNoteIfNeeded(taskID:initialWriting:)` on the first deliberate
  writing action. Use `id`, raw `content`, format and revision metadata to
  open the document. `PhoneNoteDocument` currently makes `taskNote` read-only
  for its ordinary note editor; connect a task-aware native editor with
  lossless patches before enabling edits to existing task writing. Never
  convert rich/unknown note bytes through the plain-text editor.
- **Lifecycle / one-item integration:** parent delete and Add/Remove from Tasks
  are outside this bounded API. Their caller must preserve note bytes and
  coordinate the one-item presentation/association rules. Existing task-note
  associations remain stored when a subtask is soft-deleted.
- **Xcode project and verification:** `Scripts/generate_project.rb` discovers
  the new Swift sources under `AtticMobile/` and `AtticMobileTests/`.
  Regenerate the project and run `PhoneTaskSubtasksTests` on the Air under the
  lead's verification workflow. No device build or simulator test was run in
  this bounded task.
