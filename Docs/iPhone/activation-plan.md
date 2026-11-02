# Attic · iPhone + CloudKit activation and validation plan

Draft, 2 Nov 2026. Read against branch `phase-3/pd-wave2` (`9a67432b`). Sources: the Development Contract (`AGENTS.md` / `claude.md`), `iphone/sync-study.md`, `phaseX/panel-design/improvements-build/iphone-inspired-report.md`, `phase2/owner-decisions.md`. Everything marked **Recommended** is this plan's proposal, not an owner decision. The owner decisions this plan rests on are recorded ones: "design now, build after Phase 3" (19 Oct), "iPhone back in design" and "iPhone gets its own look" (1 Nov), and "Calendar A + rows 2" (2 Nov).

## 1. Scope at activation

**The iPhone app** is the phone-first design in `iphone-inspired/index.html`, not a copy of the Mac: Home (search, recent cards, All notes, Canvases, Pinned, Tags), Tasks (Now / Later / Done with the pill row), Calendar (week strip growing into the month, time-left rows), the Notes editor, Draw, Search, and "+" quick capture. The owner wants full, editable access to all data on the phone, so sync is the foundation, not an add-on. The page-by-page list belongs to the iPhone Planning file, which is being written separately; this plan doesn't repeat it.

**Stays Mac-only (Recommended):** the menu-bar panel and its window chrome, hide animations, the corner-hover trigger, agent and Claude integrations that run on the Mac (the phone shows their pending proposals; see §8), the preview-only labs, and the old Canvas boards (out of scope until the Phase 4 rebuild replaces them).

## 2. Identities

| Item | Proposed value |
|---|---|
| Mac app | `com.taha.Attic`, unchanged |
| iOS app | **Recommended** `com.taha.AtticMobile`, tests `com.taha.AtticMobileTests` / `com.taha.AtticMobileUITests` (keeps it outside the Mac's `com.taha.Attic.<preview>` namespace) |
| iOS previews | `com.taha.AtticMobile.<preview>` |
| Mac sync test identity | **Recommended** `com.taha.Attic.syncdev`, so Development sync never touches the owner's real stores or the `preview.personal` / `preview.notesv2` / `preview.main` data |
| Team | `ZGZWS73268` for every target |
| CloudKit container | **Recommended** `iCloud.com.taha.Attic`, created by the owner in their own developer account and shared by both apps |

**Never** `com.emanueledipietro.*`, team `HR24WHR326`, or `iCloud.com.emanueledipietro.Attic`. Today those still sit in `Scripts/generate_project.rb:377–427` (mobile targets), `AtticMobile/AtticMobile.entitlements`, `Attic/Attic.entitlements`, `Attic/AtticDebug.entitlements`, `Attic/AtticLocal.entitlements`, and `PersistenceController.cloudKitContainerIdentifier` (line 11). Stage 2 replaces them. The new CloudKit entitlements files are written only after the owner has created the container (no speculative entitlements).

**Stores:** Development and Production each get their own store file, sync-engine state, outgoing queue and change tokens. `PersistenceController` already keeps Development and Production store URLs apart; the sync state follows the same split and is keyed by iCloud account too.

**Local-only Mac builds stay exactly as now.** `ATTIC_LOCAL_ONLY` stays on the Mac's Local, Debug and Release configurations, with `AtticNotesLocal.entitlements` and SwiftData's `cloudKitDatabase: .none`. Sync compiles only under a new flag, **Recommended** `ATTIC_CLOUD_SYNC`, in separate build configurations. The generator refuses to set both flags at once. Following the study, sync is a new capability that is switched on, not `ATTIC_LOCAL_ONLY` taken away: removing the flag today would wake the old `.private(oldContainer)` mirroring path and the old schema bootstrap (`AppCoordinator.swift:448`). Stage 5 deletes that dormant mirroring code.

## 3. Shared core

**Moves into a shared package (Recommended `AtticCore`, Swift package, macOS 26 + iOS):** the SwiftData models and schema registry, the stores and services (TaskStore, NoteStore document transactions, LinkStore, TagColourStore, cleanup, history and versions), the Notes document format and codecs, Calendar data and logic (EventKit adapters), design tokens (`Design/`, plus the colour and type values in `DesignSystem/`), Draw engine maths and records, Workspace logic, and the new sync engine. AppKit-only pieces stay behind `#if os(macOS)` or move to the Mac target.

**Gets new iOS UI:** every screen; the Notes editor on TextKit 2 / UIKit; long lists (Tasks, All notes, Search results) in UIKit collection views; Draw touch and Apple Pencil input (coalesced and predicted touches) over the shared engine. Simple screens (Home, Settings, sheets, Calendar headers) in SwiftUI. **Recommended:** the UIKit-for-editor-and-long-lists split comes from an owner-shared benchmark. Stage 3 measures it on Attic's own content before it's adopted (see the stage 3 gate).

**How much is reused.** In the orchestrator's measurement, files that don't import AppKit hold about 66,700 of Attic's 162,300 lines (41 %). Services (91 %), Models (90 %), Design (100 %), Calendar (80 %) and Workspace (84 %) come across nearly whole. Draw (48 %), Tasks (26 %), DesignSystem (23 %) and Notes (20 %) keep their logic but lose their UI. Window, App and Performance are Mac-only. That figure is an upper bound, because a file that doesn't import AppKit can still use macOS-only SwiftUI APIs. Most of the UI is new work, which is expected now that the iPhone has its own design.

## 4. Sync

**Approach (from the study, Recommended):** keep SwiftData as the local database and add **`CKSyncEngine` with explicit private-database records**. Don't use SwiftData's built-in mirroring, and never run both over the same data.
- Each note revision is synced as one immutable whole document (note UUID, revision UUID, parent revision, format, digest, attachment manifest). A small mutable "head" record says which revision is current.
- Offline forks keep both branches and go to visible review. No silent last-writer-wins. Block merging can come later; no CRDT is needed.
- Each local save writes its outgoing intent in the same transaction, so a crash can replay it. Every writer is hooked: TaskStore, document transactions, Draw/Canvas, LinkStore, TagColourStore, cleanup, restores and library commands.
- Imports are transactional and idempotent. The checkpoint advances only after commit, imports never echo back out as new local edits, and presentation gets fresh `ModelContext`s.
- Revisions and assets are published before the head moves. A missing asset reads as "waiting to download", never as deleted.
- Deletions are tombstones with a retention rule. Device-local rows (`StoreMaintenance`, crash journals, Undo, selection, thumbnails) never sync.

**Model and schema changes.** All 19 models in today's Mac registry already use optional or defaulted attributes, with no `@Attribute(.unique)` and no `@Relationship` (`testEveryModelIsCloudKitCompatible` checks this), so no blanket repair is needed. What's needed is additive:
- sync metadata (record system fields, outgoing queue, engine state, tombstones), all optional or defaulted, under the same test;
- revision ancestry on `NoteVersion`;
- task attachments as synced payloads instead of local file references (Phase 3's `TaskAttachmentMigrationRecord` work is the base);
- an explicit synced-type list beside `appModelTypes`. The iOS registry, now 6 models, becomes that same list.

**Contract rules kept:**
- **UUID duplicate safety.** A record name is the type plus the UUID, so all physical replicas map to one record. Imports write to every replica, and divergent replicas are kept and flagged before export, never collapsed. Two task notes created offline for the same task go to review, with no uniqueness constraint.
- **Done cleanup.** Each device keeps using `completedAt` against its own local start of day, and a divergent duplicate still blocks it. **Recommended:** a device runs destructive cleanup only after a fetch completes in that session, so it can't delete a task another device has just reopened. Cleanup deletions sync as tombstones.

## 5. Stages and gates

| # | Stage | Done when |
|---|---|---|
| 1 | **Contract update** | Owner approves `contract-update-draft.md`. It's pasted verbatim into `AGENTS.md` and `claude.md` (diff of the contract blocks is empty), and this plan's §8 answers are recorded in `owner-decisions.md`. |
| 2 | **Shared core** (starts once Phase 3's data has settled, per the 19 Oct decision) | `AtticCore` builds for macOS and iOS. Former-owner identities are gone from the build inputs. Project regenerates and `verify_project_generation.rb` passes. The Mac's local-only build and its full unit and round-trip tests pass with no new failures against the base branch. A local-only Mac preview behaves as before. |
| 3 | **iOS shell in the Simulator** | `AtticMobile` builds local-only (`ATTIC_LOCAL_ONLY`, no CloudKit or APNs entitlements) and runs in the Simulator on the shared store code with seeded data. iOS unit tests pass. UIKit-vs-SwiftUI measurement done: a 2,000-row task list and a long table-heavy note, scroll hitches and typing latency, recorded before the editor and list waves commit (confirmed on a real iPhone in stage 6). |
| 4 | **Page waves** (order from the iPhone Planning file) | Each wave: Simulator build, tests, a Sol on-screen check against the drawing, and document round trips (Mac-written note opens and saves on iOS byte-stable). Still local-only. |
| 5 | **Sync in Development** | First, two replicas pass against a fake transport: crash replay, duplicate and out-of-order delivery, stale acknowledgements, offline forks, tombstones, interrupted assets, account change. Then `syncdev` Mac and the iOS app sync through the owner's container, Development environment, development APNs. The Development schema in CloudKit Console matches a checked-in schema snapshot. Old mirroring code removed. |
| 6 | **Real-device two-way sync** | The study's verification matrix passes on the owner's Mac and iPhone (initial import both ways, normal edits, offline fork, delete and restore, large and partial assets, lifecycle, accounts, environment isolation, Undo and history, time zones and cleanup). Installed entitlements inspected. Owner tries the combined app. |
| 7 | **Production schema** | Owner deploys the schema to Production. A Production-configured build on both devices syncs two ways in Production, with separate stores and production APNs. The owner's real library is backed up before the official `com.taha.Attic` turns sync on, and only with the owner's go. |
| 8 | **TestFlight** | Owner uploads the iOS build to TestFlight, installs it, and repeats a short two-way check against Production with the release Mac build. |

## 6. Validation checklist (the contract's deferred list)

| Contract item | Check that proves it |
|---|---|
| Container owned by Taha's account | CloudKit Console lists `iCloud.com.taha.Attic` under team `ZGZWS73268`. `codesign -d --entitlements -` on each installed app names only that container. `git grep emanueledipietro` finds nothing in build inputs or source. |
| Deliberate Mac/iPhone scope and model parity | §1 scope recorded. A unit test asserts that the iOS registry equals the synced-type list and that every Mac model is either in it or on the named local-only list. |
| Matching Dev/dev APNs and Prod/production APNs | Generator check (exists for mobile at `generate_project.rb:400`, extended to the Mac sync configurations) plus installed-entitlement inspection of each configuration: `icloud-container-environment` and `aps-environment` agree. |
| Separate Development and Production stores | Test: the store URLs, engine-state files, queues and tokens for the two environments are disjoint. Stage 7 shows a Production build starting with an empty Production state. |
| CloudKit-compatible models | `testEveryModelIsCloudKitCompatible` covers the new sync models. Record round-trip tests cover every synced type. |
| Remote-notification registration | Device log shows an APNs token on Mac and iPhone. A change on one device triggers a fetch on the other without being opened. |
| Remote-change and CloudKit-event observation | For `CKSyncEngine` these are its events (account change, fetched and sent changes, state update). Tests inject each one; device logs show them in stage 6. |
| Fresh-context import refresh | Test: after an import, the presented note or task comes from a new `ModelContext` with the imported values, never a stale object. |
| Bounded event-driven activity assertions | Test: every `beginActivity` around a fetch or send ends on success, failure and timeout. |
| Development schema inspection | Console schema compared with the checked-in snapshot at the end of stage 5. |
| Production schema deployment | Owner's deploy in stage 7, then a Production fetch and send on both devices. |
| Installed-app entitlement inspection | `codesign` output for the installed Mac and iOS apps, for every configuration that ships, recorded in the stage report. |
| Real-device two-way validation | The stage 6 matrix in Development and the stage 7 and 8 checks in Production, each recorded with commit, identities, devices and OS versions. |

## 7. What only the owner can do

- Create `iCloud.com.taha.Attic`, register the `com.taha.AtticMobile` and `com.taha.Attic.syncdev` App IDs, and enable iCloud and Push for them and for `com.taha.Attic`.
- Sign CloudKit-entitled builds on their own account. Agents use ad hoc signing and can't produce these.
- Register their iPhone and turn on Developer Mode on it.
- Deploy the Production schema (once deployed, Production record types and fields can't be removed).
- Create the App Store Connect record and run TestFlight uploads and installs.
- Test on real devices, approve which data is used, and give the go before the real library starts syncing.

## 8. Open owner decisions (each with a Recommended default)

1. **Canvas on iPhone at first.** Default: new Draw boards sync and are editable (the design includes Draw). Their sync waits for the Mac's Draw schema to freeze. Old Canvas boards are not shown or synced.
2. **Visible conflict review.** Default: whole-note revisions; an offline fork shows both versions with "keep this / keep both". The same review covers duplicate task notes and edit-versus-delete. Automatic paragraph merge comes later.
3. **Attachment download policy.** Default: all metadata everywhere; files download when opened; recent and pinned items cached; a per-note "Keep offline". Nothing is ever shown as deleted while it's still downloading.
4. **History on iPhone.** Default: versions and Claude's pending proposals sync. The phone shows history and can restore (a restore is a new revision). Proposals are reviewed on the Mac in the first release; Undo stays per device.
5. **Account switching.** Default: one private iCloud account per library. On sign-out or a different account, sync pauses, local data stays on the device, and nothing uploads to the new account without asking. A device that comes back after a long time offline re-fetches before it sends.
6. **Minimum iOS.** Default: iOS 26, matching the Mac's macOS 26 and the design's glass capsules. The dormant target's iOS 17 would mean back-porting shared code.
