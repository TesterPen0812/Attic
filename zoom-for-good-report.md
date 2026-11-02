# Zoom for good — work in progress, 2 Nov

**Not ready to merge.** Zoom and glass fixes, recorded-event screen replay,
the complete state matrix and regression runs remain outstanding. The Air is
at its login window following the probe incident below. Its screen lock is
retained as instructed. No input, app launches or captures were made on the Pro.

**Findings and implemented change.** On base `9f6a841a`, HID magnify samples
went to Finder while Attic was inactive, both with a key panel and after a
non-key reveal. Activating Attic changed the target PID and zoom worked.
`Attic/Window/AtticPanel.swift:353` makes the panel key without activating the
app. Background gesture window tags are a promising lead, not yet a verified
fix. Synthetic command-scroll worked; this does **not** explain the recorded
trackpad failure. The recordings add paired HID 6 gestures to scrolls and HID
0/4 touch/mode events to pinches. Their decoded magnify events are valid
NSEvents; delivery and recognizer behavior still need replay validation.

The pen cursor formerly multiplied stroke width by zoom. At
`Attic/Draw/Engine/DrawBoardView.swift:56` it now has a fixed 6 pt diameter,
with the existing 0.6 pt outer white ring: 7.2 pt image, centre hot spot
(3.6, 3.6). The eraser remains 12 pt; other tools retain native cursors.
Base screen probes read actual system-cursor image hashes and hot spots:
the pen changed from 3.7 pt at 67% to 5.2 pt at 133%. An inactive, non-key
reveal showed the arrow instead, so background cursor delivery is still open.
The revised size has compiled but has not yet received screen verification.

**Reproducer.** `Scripts/check_draw_zoom.zsh zoombase` (or `zoomfix`) runs on
the Air with that preview open on Draw and the screen lock held. It rebuilds
recorded CGEvents, translates their path, preserves callback order and timing,
posts at the session tap, and asserts change through the zoom pill's AX value.
Fixtures in `AtticTests/Fixtures/DrawTrackpad` retain exact consecutive lines
from recording 2, with provenance and ranges. The command currently checks the
current state; automatic preparation of the complete matrix is pending. It has
compiled, but **has not run** against either preview with the real recordings.

**Tests and builds.** Tests were committed before the corresponding fixes.
`DrawInputTests.testThePensCursorFollowsItsColourButKeepsItsScreenSize` and
`testEveryToolCursorHasTheSameImageAndHotSpotAtEveryZoom` were red first:
2 tests, 16 expected assertions, saved in `.build/red.log`.
The two `testOwnersRecorded…` tests (complete streams; selection/text editor)
compile. Their attempted run and tmux retry executed **zero tests** because
`com.apple.testmanagerd.control` was unavailable after logout; these are not
red runs or passes. `FirstClickActivationTests` is committed and compiles,
but has not run. Green cursor runs, every Draw suite, first-click, chrome,
hide/swipe and other affected suites remain required. Project generation and
repeatability checks pass. Optimized ad-hoc previews built successfully:
base identity `com.taha.Attic.preview.zoombase`; cursor-only review at
`01f95834`, identity `com.taha.Attic.preview.zoomfix`, executable `AtticZoomFix`,
SHA-256 `34762b22fee7489dca15227698f17439cf610b53224e325b1e775b5196049f11`.

**Incident and evidence.** At 03:43:49 a hand-built touch/boundary payload
asserted in WindowServer gesture annotation and logged the Air out. It used
guessed private fields, including incorrect touch flags/coordinate keys;
the exact assertion condition is not established. That generator has been
removed. Replay now accepts recorded streams only, at the session tap, with
login, modifier and own-window checks. Evidence is under
`phaseX/panel-design/onscreen-zoom-for-good/`: `base-routing-pids.log`,
`base-inactive-reveal.log`, `base-stroke-streams.log`,
`unsafe-touch-probe.swift.txt`, `owner-trackpad-2-decoded.txt`,
`air-zoom-cursor-red.log`, `air-zoom-recorded*-red.log`, and
`preview-zoom-fix-build.log`. **No glass captures exist yet.** SCK before/one
click/two clicks, live cursor proof and the full input matrix await login.
The owner's real hardware must ultimately confirm feel and hardware-origin
delivery; recorded replay and hosted tests are also still outstanding.
