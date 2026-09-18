# Deep Audit Consolidation — 2026-09-15

This document consolidates the five 2026-09-14 domain audits without extending their audit scope or changing source. It is an implementation handoff for Opus High through Synara, not a claim that Attic is defect-free or release-ready.

## Audited baseline and evidence

- Checkout: `/Users/taha/Developer/attic-task-panels-v2`
- Branch and source baseline reported by the audits: `codex/attic-task-panels-v2` at `ae6418c1af690e29d15a20344cdb9765a23d3f85`, with a large pre-existing dirty worktree. File/line references describe that dirty snapshot and may move as concurrent work continues.
- Source reports: [Runtime](DeepAudit-Runtime-2026-09-14.md), [Data](DeepAudit-Data-2026-09-14.md), [Canvas](DeepAudit-Canvas-2026-09-14.md), [UX](DeepAudit-UX-2026-09-14.md), and [Integration](DeepAudit-Integration-2026-09-14.md).
- Runtime evidence was limited to one 3-second idle sample of local-only `AtticPERFA1Final` (`com.taha.Attic.perfa1final`): 0% CPU, about 80 MB RSS, four threads, panel hidden, Canvas not frontmost. It does not measure draw, erase, import, reveal churn, or MCP load.
- UX evidence came from the same local-only preview lineage and 44 native captures in [DeepAudit-UX-2026-09-14-screenshots](DeepAudit-UX-2026-09-14-screenshots). Synthetic pointer input was used; physical trackpad gestures, VoiceOver, Reduce Motion, and Reduce Transparency were not exercised.
- Integration evidence is stronger for its domain: a fresh unsigned Local `build-for-testing` succeeded and the windowless host ran 497 tests with 0 failures and 4 explained skips. An earlier same-day 799-test baseline also passed, but its tree differed by later Canvas edits and is supporting provenance rather than the acceptance gate for future changes.
- Runtime, Data, and Canvas findings are otherwise source/test-inventory evidence. Their tests were not run by those auditors.

## Counting and deduplication

There are **62 raw labeled audit items** and **55 unique consolidated items**.

The raw count includes every numbered or lettered non-dismissed item in the five reports: Runtime 15 (`RUN-001…010`, `P-01…05`), Data 5 (`AUDIT-DATA-01…05`), Canvas 24 (`CVD-01…08`, `CVP-01…09`, `CVX-01…07`), UX 12 (`UX-01…04`, `C-1…4`, `S-1…4`), and Integration 6 (`INT-01…06`). It excludes coverage statements, verified-sound areas, dismissed hypotheses, unlabeled minor observations, limitations, and the Data report's two unnumbered optional UX bullets.

The unique count subtracts seven duplicate records by collapsing five shared mechanisms:

| Unique mechanism | Raw IDs retained | Deduplication decision |
|---|---|---|
| Native Canvas bridge teardown on transient interruption | `RUN-001`, `RUN-002`, `CVD-01` | One root with two impacts: confirmed import cancellation and structurally unmeasured cache/decode churn. |
| Full-board eraser scan per accepted sample | `RUN-003`, `CVP-09` | Same call path and complexity claim. |
| Notes materialization orphan race | `AUDIT-DATA-01`, `INT-06` | Same race. Integration agrees it is Low, bounded, and self-healing; it is not promoted because it appeared twice. |
| Canvas tombstone/stale-generation retention | `CVD-07`, `INT-05` | Same unbounded dead-row retention and repeated-fetch mechanism. |
| Accent-tinted borderless image menus | `UX-01`, `C-1`, `C-3` | `C-1` and `C-3` are unexercised sites in `UX-01`'s already-confirmed mechanism, not separate defects. |

Related items with different causes remain separate. In particular, `CVD-02` is a failed-operation transaction/history defect even though it also invokes the teardown root; `RUN-007` and `INT-03` cover different AgentServer lifetime gaps; `CVD-03` and `CVD-04` cover different retry failures; and `RUN-010` payload residency is distinct from tombstoned-row retention.

## Highest-impact findings

### P0 — prevent silent user-work loss and aborts

1. **Canvas transient teardown cancels active imports and rebuilds the entire native surface** — `RUN-001` Medium/high confidence, `RUN-002` Medium structural/high mechanism confidence, `CVD-01` High/confirmed mechanism. `CanvasSurface.swift:23` keys the native bridge to `interactionCancellationEpoch`; transient callers in `CanvasPanelContent.swift:397-400`, `AtticPanelView.swift:808-810`, and `AtticPanelController.swift:468-469` cause dismantle, `cancelAllImageImportBatches`, and cache destruction. The Canvas audit rates the functional effect High; the Runtime audit rates it Medium. Adopt **High for prioritization** because the Canvas trace establishes a direct, silent cancellation of deliberate work on ordinary zoom/hide/section actions. Keep the performance magnitude unmeasured.
2. **Scroll or pinch can silently discard buffered ink** — `CVD-05`, Medium, confirmed. Unguarded viewport-gesture entry paths in `CanvasSurfaceMac.swift:872-953, 1007-1045` call `beginPan()` while drawing/erasing, replacing the input-machine state and dropping points. This is a direct core-gesture loss path.
3. **Failed Canvas select/create/delete work can erase undoability and tear down the view** — `CVD-02`, Medium, confirmed. `CanvasSession.swift:495-553` performs cancellation/synchronization without consistently gating it on store success. A whitespace-only canvas name is the simplest source-level reproducer.

### P1 — repair bounded correctness and reliability defects

4. **Image recovery does not match its plural UI contract** — `CVD-03` and `CVD-04`, each Low-Medium, confirmed. Retry acts on only the first failed image and renderer retry drops off-screen images. Fix both in one batch while keeping the mechanisms separately testable.
5. **Canvas text resize can persist clipped text** — `CVD-08`, Low-Medium, confirmed. Resize saves narrower geometry without applying the edit path's grow-to-fit calculation; pointer and keyboard minimum sizes also differ.
6. **Canvas toolbar/menu Undo and Redo bypass focused text editing** — `CVD-06`, Low-Medium, confirmed. Buttons call `CanvasSession` directly while keyboard commands correctly use `CanvasEditCommandRoute`.
7. **Notes orphan cleanup can delete an import materialization before its row commits** — `AUDIT-DATA-01` / `INT-06`, **Low**, high mechanism confidence and medium user-impact confidence. The model payload remains durable, post-commit/on-demand repair rebuilds the file, and no permanent data loss was established. Add the age or in-flight guard for reliability; do not describe this as a high-severity loss bug.
8. **MCP accepts present non-object `arguments` as `{}`** — `INT-02`, Low, high confidence. `MCPRequestHandler.swift:106` silently changes client intent and can return a misleading successful unfiltered result.
9. **AgentServer retains accepted idle connections after stop** — `INT-03`, Low, high mechanism/low impact confidence. The generation gate prevents post-stop handler access, so this is lifecycle/resource hygiene rather than a security bypass.
10. **Global hotkey registration can fail while the menu still advertises it** — `INT-04`, Low, high confidence. Registration errors are swallowed and no state reaches Settings.
11. **Confirmed UX polish defects** — `UX-01` Medium-Low confirmed source+native, `UX-02` Low-Medium confirmed source+native, and `UX-03` Low confirmed dead code with native-glass hover still unverified. They cover misleading accent tint on image-label menus, drawer rows clipping/overlapping under fixed chrome, and unused quick-submit hover state.

## Structural, unmeasured performance and resource risks

These mechanisms are real in source, but the audits did not measure a user-visible regression. Treat them as test-and-measure work rather than assumed performance emergencies.

| Item | Assessment and evidence | Consolidated disposition |
|---|---|---|
| `CVD-07` / `INT-05` | Medium in Canvas, Low-Medium in Integration; high-confidence structure. Tombstoned and stale-generation Canvas rows are retained and fetched indefinitely. | Use **Medium structural risk** for planning because lifetime growth compounds. Compaction depends on the verified local-only versus future CloudKit retention contract. Do not delete tombstones until that contract is explicit. |
| `RUN-010` | Low-Medium structural. `CanvasPlacedImage.encodedData` retains every loaded image payload in the session in addition to bounded decoded caches/history. | Measure payload residency before changing the presentation/store boundary. Independent of tombstone compaction. |
| `INT-01` | Low-Medium structural/high confidence. A parked pointer in the 96/144 pt responsive ring keeps a 50 ms timer and App Nap activity indefinitely. | Add a bounded decay only after a state-machine test, then measure the activity assertion and sampling cadence. |
| `RUN-003` / `CVP-09` | Low-Medium structural. Eraser hit testing scans remaining strokes for each accepted drag sample. | Instrument strokes scanned and gesture time on a large seeded board before selecting candidate-list versus spatial-index work. |
| `RUN-004` | Low structural with verified mitigations. A Canvas save resolves presentation twice using a fresh context. | Defer unless measurement crosses the gate; this is currently correctness-shaped persistence behavior. |
| `RUN-005` | Low. Pan/zoom allocates and cancels a debounce `Task` per event. | Batch with Canvas performance work after an allocation trace. |
| `RUN-006` | Low. Every task revision builds a full ID set for UI reconciliation. | No standalone work unless large-task measurement justifies it. |
| `RUN-007` | Low-Medium. MCP/store work is main-actor serialized; idle reads have no deadline or connection cap. | Separate main-actor latency measurement from the concrete timeout/cap/stop-lifecycle fixes. Loopback, request-size, Host/Origin, and bearer mitigations were verified. |
| `RUN-008` | Low. Each app activation can run the cleanup fetch pass even after same-day cleanup. | Add a same-day guard only with wake/day/timezone tests. |
| `RUN-009` | Trivial. Decode queue order is rebuilt twice per prepare call. | Mechanical cleanup with nearby renderer work only. |
| `AUDIT-DATA-04` | Structural only. Agent note update derives anchors with a whole-document paragraph diff. | Correct today and agents are low-frequency; measure before optimizing. |
| `CVP-02` | Plausible structural risk. Accessibility queries can rebuild/sort the full element map even when not stale. | Requires VoiceOver/a11y-client measurement; preserve first-build behavior. |
| `CVP-03`, `CVP-04` | Plausible structural risks. Semantic hit testing is linear/allocation-heavy and display objects remap repeatedly during drag. | Seeded semantic-object profiling before cache work. |
| `CVP-05` | Plausible quality/performance gap. macOS ink does not consume coalesced mouse events. | Visual/precision measurement with fast physical strokes or tablet input. |
| `CVP-06` | Bounded retention edge. Semantic text drafts can outlive deleted objects/canvases. | Add cleanup with lifecycle tests when touching semantic drafts. |
| `CVP-08` | Harmless repeated retry request on view recreation. | Likely disappears with the teardown/retry fixes; verify rather than patch separately. |
| `P-01`, `P-02`, `P-04`, `P-05` | Runtime plausible notes: currently shielded published writes, synchronous LaunchServices icon lookup, Settings activation refresh, MCP burst serialization. | No implementation until measurement or a reproducer exists. |

## Unverified functional gaps and optional suggestions

The following should remain explicitly below confirmed defects:

- `CVP-01` is the most important unverified functional gap: Canvas file-promise slot accounting may wait for advertised UTI count rather than delivered-file count. It needs a real drag from Photos/Safari or another promise provider before changing the contract.
- `UX-04` is a plausible motion-completion barrier stall with bounded recovery; it was not reproduced. Test dropped-completion behavior before adding a watchdog.
- `AUDIT-DATA-03` preserves corrupt task attachment metadata but renders it as no attachments; corruption/migration fixture only.
- `AUDIT-DATA-05` presents orphan subtasks as roots but cannot attach files to them; malformed/migrated-data fixture only.
- `P-03` is an intentional note-flush hide veto whose discoverability is unverified.
- `CVP-07` is a broad `NSTextView` match with no known conflicting text view today.
- `C-2` asks whether the Notes list is intentionally near-unreachable. It is a product question, not a defect finding.
- `C-4` records that synthetic scroll did not move panel ScrollViews; the auditor treated it as a tooling limitation. Check a physical trackpad before filing a bug.
- `CVX-01…07` are deferred-platform copy, export naming, consistency, documentation, and minor implementation notes. `CVX-04` (Space discards an in-progress stroke) needs an explicit interaction-design decision; `CVX-05` should update `CANVAS-DESIGN.md` after behavior changes land.
- `S-1…4` are optional UX choices: duplicate Notes-drawer close controls, accent empty-state CTA, non-durable quick-entry draft, and status-circle discoverability. Do not mix them into correctness batches without product approval.
- Data's unnumbered move-refusal message and accepted-then-ignored internal-drop notes remain optional UX polish and are not included in the 62/55 counts.

## Release-only identity concern

`AUDIT-DATA-02` is a **Medium, high-confidence latent activation/release concern**, not a defect in the currently audited Local build. `PersistenceController.swift:11` and generated AtticMobile settings still name the former owner's CloudKit container, bundle identifier, and team. The Local macOS configuration was verified to compile with `ATTIC_LOCAL_ONLY` and CloudKit/APNs paths dormant.

Do not replace these strings blindly, strip entitlements, change signing teams, enable CloudKit, or turn on the mobile target during the implementation batches. Before any identity edit, obtain and verify the intended bundle ID, Apple development team, CloudKit container ownership/environment, entitlements, migration/data-continuity policy, and whether AtticMobile is meant to remain excluded or local-only. If those inputs are absent, keep this as a release blocker with the deferred paths disabled.

## Coverage and native limitations

The five audits collectively read the app entry/lifecycle, Tasks, Notes and drafts, task/note attachments, Canvas engine/store/native surface, Settings, window/panel controllers, corner monitor, MCP/HTTP/token paths, persistence, and relevant test inventories. Integration additionally built the Local unit-test products and ran its 497-test domain set. UX rendered the main/subpanel, task rows, Notes editor/drawer/attachment picker, all Settings panes, and core Canvas controls/drawing.

The UX audit now provides direct provenance for **task-row click opening the family subpanel** in `AtticPERFA1Final`: row single-click opened the anchored family panel, pin promoted it, and the pinned subpanel survived main-panel hide. This supersedes earlier inconclusive QA only for those observed actions. It does not prove every switching, drag, keyboard, accessibility, relaunch, or multi-display state.

Not validated as working: CloudKit, APNs, iPhone/AtticMobile, TestFlight, Production signing, real SDK MCP interoperability, VoiceOver structure, Reduce Motion/Transparency behavior, physical swipe-to-hide, kinetic trackpad scrolling, real task-file drag/drop, Canvas file promises from external providers, pinned-subpanel relaunch behavior, multi-display corner moves, large-store performance, or long-duration storage behavior. The idle sample does not prove active performance. Passing source/build/tests does not substitute for native interaction checks.

## Implementation batches for Opus High through Synara

Each batch should start by recording branch, HEAD, dirty status, and hashes for the files it owns. Preserve unrelated changes. Use the audited dirty snapshot as provenance, then re-resolve line numbers against the live tree. Do not rewrite the Canvas architecture or weaken persistence, replica, draft, security, or local-only safeguards.

### Batch 1 — Canvas lifecycle and failed-operation correctness

**Own:** `CanvasSurface.swift`, `CanvasSurfaceMac.swift`, `CanvasSurfaceInteraction.swift`, `CanvasSession.swift`, the transient callers in `CanvasPanelContent.swift`, `AtticPanelView.swift`, and `AtticPanelController.swift`, plus focused Canvas/session tests.

**Fix:** `RUN-001` / `RUN-002` / `CVD-01`, `CVD-02`, and `CVD-05`. Split transient interaction interruption from lifecycle teardown; keep session-owned imports alive across hide/zoom/section changes; gate history reset and teardown on successful board operations; refuse viewport takeover while ink/image/shape interaction is active.

**Dependencies:** none on identity or release work. Coordinate caller edits with the panel owner because `AtticPanelView` and `AtticPanelController` are shared UI files. Preserve legitimate teardown on successful board lifecycle and termination.

**Verification gate:** focused tests proving epoch stability and import completion on zoom/hide, invalid canvas creation preserving undo/history, scroll/pinch preserving buffered ink, legitimate board switch and termination still canceling the right interaction, then the repository Local build/test gate. Native: multi-image import while zooming/hiding/switching; physical draw plus incidental trackpad input; panel/subpanel smoke check.

### Batch 2 — Canvas recovery, editing, and text layout

**Own:** `CanvasSession.swift`, `CanvasSurfaceRenderer.swift`, `CanvasPanelContent.swift`, `CanvasEditCommandRoute.swift`, semantic resize/layout helpers, and focused tests.

**Fix:** `CVD-03`, `CVD-04`, `CVD-06`, `CVD-08`, and `CVX-06`. Retry all failed image IDs and make retry valid off-screen; route toolbar/menu Undo and Redo through the focused-editor command route; grow text geometry after narrowing and unify resize minimums.

**Dependencies:** land after Batch 1 because view recreation/retry replay behavior changes there. Avoid broad cache redesign.

**Verification gate:** two-failure retry test including one off-screen image; focused text editor toolbar/menu undo tests; resize multi-line text narrower and verify no clipping plus pointer/keyboard minimum parity; Local build/tests; native Canvas editor/recovery check.

### Batch 3 — Attachment reconciliation and protocol lifecycle

**Own:** `AttachmentFileStore.swift`, minimal `NoteStore.swift` coordination if needed, `MCPRequestHandler.swift`, `AgentServer.swift`, `GlobalHotKey.swift`, the Settings status surface, and focused integration/unit tests.

**Fix:** `AUDIT-DATA-01` / `INT-06`, `INT-02`, `INT-03`, and `INT-04`. Give notes cleanup the existing task-side recency or explicit in-flight protection; reject present non-object MCP arguments; track/cancel accepted connections on stop and add the separately justified read timeout/cap if included; expose hotkey failure honestly.

**Dependencies:** no Canvas dependency. Keep task and note attachment roots separate. Preserve loopback binding, Host/Origin validation, constant-time token comparison, request cap, generation gate, and fail-closed credential behavior.

**Verification gate:** deterministic import/reconcile interleaving with no reliance on self-heal; true old orphans still removed; non-object argument cases return `-32602`; partial/idle socket closes on stop and timeout; restart still binds; injected Carbon registration error reaches Settings; 497-domain baseline and full Local suite.

### Batch 4 — Confirmed UX repairs

**Own:** the eight menu sites enumerated by `UX-01`, `SavedNotesDrawer`, quick-submit rendering/focus state, and narrow focused UI/source tests.

**Fix:** `UX-01`, `UX-02`, and `UX-03`. Reuse the proven quiet menu treatment; retain accent only for true pending shape placement; prevent drawer rows from overlapping fixed chrome; make submit hover and keyboard focus visible across native-glass, material, and opaque treatments.

**Dependencies:** follow shared-file edits from Batches 1–2 in `CanvasPanelContent.swift`/`AtticPanelView.swift`. Do not include `S-1…4` or Notes navigation redesign.

**Verification gate:** rendered dark/light and Clear/Frosted/opaque states; idle versus pending shape signal; drawer with at least eight notes at both scroll extremes; pointer hover and keyboard focus; Reduce Transparency if it can be tested in an isolated host; regression check that task-row menu treatment remains correct.

### Batch 5 — Measured resource hardening

**Own:** one mechanism at a time after baseline measurement: corner sampling (`INT-01`), Canvas tombstone/store persistence (`CVD-07` / `INT-05`), loaded image payload residency (`RUN-010`), eraser candidates (`RUN-003` / `CVP-09`), then only measured smaller items.

**Fix:** only the risks whose pre-change measurement or deterministic growth test demonstrates the stated cost.

**Dependencies:** tombstone compaction requires a written retention decision: local-only compaction behavior, future CloudKit resurrection/grace rules, and migration expectations. It does **not** require changing account/team/container identity. Payload residency may require a store accessor but should remain separate from tombstone work. Batch 1 should land before measuring hide/show cache churn.

**Verification gate:** parked-pointer cadence/activity test plus energy/sample comparison; seeded tombstone/stale-generation row-count and fetch-counter test preserving presentation; payload byte-residency measurement; 5,000-stroke eraser timing/scanned-count gate; full Local test suite and targeted native performance check. Reject optimizations that weaken replica resolution, undo/history bounds, external-storage integrity, or deterministic hit testing.

### Batch 6 — Reproduce before fixing unverified gaps

**Own:** short isolated investigations for `CVP-01`, `UX-04`, `C-4`, `AUDIT-DATA-03`, `AUDIT-DATA-05`, `P-03`, and accessibility/query performance.

**Fix:** only after the specified real-provider, physical-input, corruption-fixture, malformed-data, failed-flush, or VoiceOver reproducer succeeds.

**Dependencies:** wait for Batches 1–4 where their changes may remove or alter the symptom. Product choices (`C-2`, `CVX-04`, `S-1…4`) require explicit decisions rather than engineering inference.

**Verification gate:** attach the reproducer and before/after evidence to each resulting change. Close a hypothesis as unconfirmed if it cannot be reproduced under its required native condition; do not convert tooling failures into app bugs.

## Complete ID inventory and disposition

The source reports remain authoritative for exact evidence and verification prose. This inventory preserves every raw ID, its stated confidence, and its consolidated class.

### Runtime

| IDs | Report assessment | Consolidated class |
|---|---|---|
| `RUN-001`, `RUN-002` | Medium/high confidence functional abort; Medium structural/high mechanism confidence cache churn | Highest-impact shared Canvas teardown root; merged with `CVD-01` |
| `RUN-003` | Low-Medium structural | Unmeasured eraser risk; merged with `CVP-09` |
| `RUN-004` | Low structural, mitigations verified | Unmeasured persistence cost |
| `RUN-005` | Low | Unmeasured allocation churn |
| `RUN-006` | Low | Minor structural allocation |
| `RUN-007` | Low-Medium | Agent main-actor/connection-bound structural risk |
| `RUN-008` | Low | Cleanup activation overhead |
| `RUN-009` | Trivial | Mechanical renderer cleanup |
| `RUN-010` | Low-Medium structural | Unmeasured payload residency |
| `P-01` | Plausible; zero cost today | Deferred |
| `P-02` | Plausible; unmeasured | Deferred |
| `P-03` | Intended veto; discoverability unverified | UX verification gap |
| `P-04` | Plausible; cheap | Deferred |
| `P-05` | Plausible burst behavior | Measure before optimization |

### Data and reliability

| ID | Report assessment | Consolidated class |
|---|---|---|
| `AUDIT-DATA-01` | Low; high mechanism/medium impact confidence; self-healing | Confirmed bounded reliability defect; merged with `INT-06` |
| `AUDIT-DATA-02` | Medium, high confidence; latent in Local | Release-only identity concern; blocked on verified intended identity |
| `AUDIT-DATA-03` | Plausible, corrupt-store only | Unverified data visibility gap |
| `AUDIT-DATA-04` | Structural only, rare/correct | Measure before optimizing |
| `AUDIT-DATA-05` | Plausible, malformed/migrated data only; Low | Unverified consistency gap |

### Canvas

| IDs | Report assessment | Consolidated class |
|---|---|---|
| `CVD-01` | High, confirmed mechanism | Highest-impact shared teardown root; merged with `RUN-001/002` |
| `CVD-02` | Medium, confirmed | Functional defect |
| `CVD-03`, `CVD-04` | Low-Medium, confirmed | Separate functional retry defects, one implementation batch |
| `CVD-05` | Medium, confirmed | Silent work-loss defect |
| `CVD-06` | Low-Medium, confirmed | Editing-command correctness defect |
| `CVD-07` | Medium, confirmed structure/unmeasured growth | Structural retention risk; merged with `INT-05` |
| `CVD-08` | Low-Medium, confirmed | Persistent presentation correctness defect |
| `CVP-01` | Plausible, live provider required | Unverified functional gap |
| `CVP-02` | Plausible, client-driven cost | Accessibility performance gap |
| `CVP-03`, `CVP-04` | Plausible structural | Semantic-object performance gaps |
| `CVP-05` | Plausible, visual effect unmeasured | Native precision gap |
| `CVP-06` | Bounded retention edge | Minor structural risk |
| `CVP-07` | Low risk, no conflicting view known | Deferred hardening |
| `CVP-08` | Harmless no-op interaction | Verify after teardown/retry changes |
| `CVP-09` | Structural | Merged with `RUN-003` |
| `CVX-01` | Deferred-iOS copy issue | Optional/deferred platform |
| `CVX-02` | Export label over-promises | Optional UX copy |
| `CVX-03` | Safe but inconsistent commit/suspend behavior | Optional consistency |
| `CVX-04` | Deliberate Space-to-pan path can discard ink | Product interaction decision |
| `CVX-05` | Documentation materially stale | Documentation follow-up after behavior changes |
| `CVX-06` | Resize minimum inconsistency | Fold into `CVD-08` implementation, retained as a separate raw item |
| `CVX-07` | Cheap set/string recomputation | No standalone work |

### UX/UI

| IDs | Report assessment | Consolidated class |
|---|---|---|
| `UX-01`, `C-1`, `C-3` | Medium-Low confirmed source+native for core sites; extra sites pattern-confirmed but not exercised | One visual mechanism |
| `UX-02` | Low-Medium, confirmed source+native | Confirmed layout/readability defect |
| `UX-03` | Low, confirmed dead code; native-glass response unverified | Confirmed fallback/custom-feedback defect |
| `UX-04` | Plausible, bounded recovery, not reproduced | Unverified lifecycle hardening |
| `C-2` | Product intent question | Decision, not defect |
| `C-4` | Tooling limitation; physical scroll likely fine | Native verification gap |
| `S-1` | Optional duplicate close affordance | Suggestion |
| `S-2` | Optional empty-state styling | Suggestion |
| `S-3` | Optional quick-entry durability choice | Suggestion |
| `S-4` | Optional status-target discoverability | Suggestion / physical-pointer check |

### Integration

| ID | Report assessment | Consolidated class |
|---|---|---|
| `INT-01` | Low-Medium, high mechanism confidence; energy unmeasured | Structural resource risk |
| `INT-02` | Low, high confidence | Confirmed protocol correctness defect |
| `INT-03` | Low, high mechanism/low impact confidence | Confirmed bounded lifecycle defect |
| `INT-04` | Low, high confidence | Confirmed reliability/UX defect |
| `INT-05` | Low-Medium, high-confidence structure | Merged with `CVD-07`; severity reconciled to Medium structural risk |
| `INT-06` | Low, high confidence; bounded/self-healing | Merged with `AUDIT-DATA-01`; remains Low |

## Release acceptance gates

After all selected implementation batches, rerun a fresh Local build-for-testing and the full current suite from the final tree, then perform native checks for the interactions actually changed. Compare from a recorded final SHA and bundle identity. Keep skipped tests explicit. Review the final diff for unrelated changes.

Do not represent that evidence as CloudKit/mobile/release validation. Production or mobile work remains blocked until intended account/team/container identities and data-continuity requirements are verified. The consolidated result establishes prioritized, bounded work and a verification route; it does not establish exhaustive app perfection.
