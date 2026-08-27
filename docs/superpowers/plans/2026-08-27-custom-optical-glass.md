# Custom Optical Glass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the branch’s Core Image material-filter experiment with a public ScreenCaptureKit plus Metal optical backdrop that has honest fallbacks, independent controls, real performance presets, adaptive quality, deterministic tests, and privacy-safe metrics.

**Architecture:** Keep the existing SwiftUI panel as an undistorted foreground. An AppKit backdrop view owns a generation-safe ScreenCaptureKit session, a frame-driven Metal renderer, and a native material fallback. Pure workload, geometry, adaptive, lifecycle, and metrics types remain independently testable.

**Tech Stack:** Swift 5, AppKit, SwiftUI, ScreenCaptureKit, MetalKit, CoreVideo, CoreMedia, CoreGraphics screen-capture permission APIs, IOKit power-source notifications, OSLog/signposts, XCTest, Xcode project generation.

**Spec:** `docs/superpowers/specs/2026-08-27-custom-optical-glass-design.md`

## Global Constraints

- Work only on `experiment/custom-optical-glass`; never update or merge `main`.
- Preserve Tasks, Backlog, Notes, accepted squircle, 10–140 pt radius, width controls, adaptive insets, mask, disabled rectangular shadow, and hit region.
- Never sample or displace Attic’s foreground content.
- Use public APIs only; no private WindowServer API, static desktop image, fake rim, or focus-dependent profile.
- Do not modify identifiers, signing, entitlements, CloudKit/APNs, stores, SwiftData schema, sync, production data, or mobile behavior.
- Refraction 0 is exact identity. Off and hidden release capture/GPU resources.
- Screen Recording permission is requested only by an explicit user action.
- Advanced controls are collapsed by default.
- Commit and push coherent milestones; do not create a PR, merge, install, upload, deploy, or release.

---

### Task 1: Design and execution contract

**Files:**
- Create: `docs/superpowers/specs/2026-08-27-custom-optical-glass-design.md`
- Create: `docs/superpowers/plans/2026-08-27-custom-optical-glass.md`

**Interfaces:**
- Produces the authoritative architecture, workload table, lifecycle, fallback, privacy, and validation contract used by every later task.

- [ ] Commit both documents atomically on the current branch head.
- [ ] Verify the branch remains a descendant of `4c131e68437b857c8a5b97e365bcf84419de4f4e` and `main` is untouched.

### Task 2: Failing preset, adaptive, lifecycle, fallback, and metrics tests

**Files:**
- Create: `AtticTests/OpticalWorkloadTests.swift`
- Create: `AtticTests/OpticalAdaptiveQualityTests.swift`
- Create: `AtticTests/OpticalCaptureLifecycleTests.swift`
- Create: `AtticTests/OpticalPerformanceMetricsTests.swift`
- Modify: `AtticTests/AppSettingsTests.swift`
- Modify: `.github/workflows/macos-ci.yml`

**Interfaces:**
- Tests require `OpticalPerformancePreset`, `OpticalWorkloadProfile`, `OpticalAdaptiveInputs`, `OpticalAdaptiveQualityController`, `OpticalCaptureLifecycle`, `OpticalFallbackReason`, `OpticalBackdropMode`, `OpticalPerformanceMetrics`, and persisted `AppSettings.glassPerformancePreset`.

- [ ] Add tests asserting Off/Low/Balanced/Maximum workload values exactly match the design table and differ in capture scale, fps, queue depth, blur samples, edge evaluations, band, and displacement.
- [ ] Add tests proving presets do not rewrite Transparency, Frost, Refraction, or Advanced values and Refraction 0 resolves to zero band/displacement in every enabled workload.
- [ ] Add adaptive tests for hidden Off, battery/Low Power/thermal/scale ceilings, three-window degradation, six-window plus twenty-second upgrade hysteresis, and focus invariance by construction.
- [ ] Add lifecycle tests for duplicate-start suppression, fresh generations, stale-frame rejection, hidden/off stop, and release actions.
- [ ] Add fallback tests for permission not requested/denied, capture unavailable, Metal unavailable, Reduce Transparency, and authorized live optics.
- [ ] Add aggregate metrics tests for mean frame time, dropped rate, latency, memory estimate, bounded rolling windows, and absence of image payload fields.
- [ ] Extend settings tests for Balanced default, Off/Low/Balanced/Maximum/Adaptive persistence, invalid-value fallback, legacy opaque-to-Off migration, and existing optical-installation-to-Balanced migration.
- [ ] Allow pushes to `experiment/custom-optical-glass` to run the existing macOS CI workflow without changing its build/test/analyze steps.
- [ ] Push the failing-test milestone and inspect CI; expected failures must be missing new symbols/behavior rather than syntax mistakes in tests.

### Task 3: Pure models, workload mapping, adaptive policy, geometry, and metrics

**Files:**
- Create: `Attic/Optics/OpticalGlassModels.swift`
- Create: `Attic/Optics/OpticalAdaptiveQuality.swift`
- Create: `Attic/Optics/OpticalGeometry.swift`
- Create: `Attic/Optics/OpticalPerformanceMetrics.swift`
- Modify: `Attic/Design/AtticStyle.swift`
- Modify: `Attic/Design/Squircle.swift`
- Modify: `Attic/Services/AppSettings.swift`

**Interfaces:**
- `enum OpticalPerformancePreset: String, CaseIterable, Identifiable`.
- `struct OpticalWorkloadProfile: Equatable` with `captureScale`, `maximumFramesPerSecond`, `queueDepth`, `blurSampleCount`, `edgeEvaluationCount`, `maximumBandPixels`, `maximumDisplacementPixels`, and `allowsLiveOptics`.
- `OpticalWorkloadProfile.forPreset(_:)` maps Off/Low/Balanced/Maximum; Adaptive is resolved by the adaptive controller.
- `OpticalGlassProfile.resolve(controls:workload:windowActivity:)` keeps axes independent and makes focus inert.
- `struct OpticalAdaptiveInputs` contains visibility, Low Power, thermal, battery, scale, and aggregate performance only.
- `mutating OpticalAdaptiveQualityController.evaluate(inputs:now:) -> OpticalPerformancePreset` implements hysteresis.
- `struct OpticalCaptureRegion` and `ScreenCaptureRegionMapper.makeRegion(...)` centralize crop/overscan/coordinate conversion.
- `final class OpticalPerformanceMetrics` records numeric aggregates only.

- [ ] Implement only enough pure code to satisfy the new tests.
- [ ] Move optical contracts out of `AtticStyle.swift`; leave style constants and the accepted foreground squircle clip there.
- [ ] Retain and adapt the continuous boundary/synthetic-grid math; maximum workload must target 36 px and 24 px, Balanced 32 px and 19 px, Low 28 px and 12 px.
- [ ] Persist the selected preset and run one-time migration without changing existing independent values.
- [ ] Run CI, fix production code rather than weakening tests, and commit the green pure-model milestone.

### Task 4: Explicit permission and ScreenCaptureKit lifecycle

**Files:**
- Create: `Attic/Optics/OpticalPermissionController.swift`
- Create: `Attic/Optics/OpticalCaptureSession.swift`
- Modify: `Attic/Info.plist`
- Modify: `AtticTests/OpticalCaptureLifecycleTests.swift`

**Interfaces:**
- `enum OpticalCapturePermissionState { case notRequested, authorized, denied }`.
- `@MainActor final class OpticalPermissionController: ObservableObject` accepts injectable preflight/request/open-settings closures for tests and exposes `requestAccess()` only for explicit UI use.
- `struct OpticalCaptureConfiguration: Equatable` contains display ID, source region, pixel size, fps, queue depth, and generation.
- `protocol OpticalCaptureSessionProtocol` exposes `start(configuration:)`, `update(configuration:)`, and `stop()`.
- `final class OpticalCaptureSession` uses `SCShareableContent`, excludes Attic’s process, creates `SCStream`, delivers complete `CVPixelBuffer` frames, records incomplete/dropped frames, and releases all references on stop.

- [ ] Add permission-controller tests before implementation.
- [ ] Add `NSScreenCaptureUsageDescription` with honest sampling/exclusion/no-storage copy.
- [ ] Implement explicit permission state without prompting during app launch or panel reveal.
- [ ] Implement display selection, self-excluding content filter, crop configuration, frame output, stale-generation rejection, start/update/stop, and bounded failure state.
- [ ] Ensure stop removes outputs, stops capture, clears latest frames, and releases stream/filter/configuration references.
- [ ] Run CI and commit the capture/permission milestone.

### Task 5: Metal renderer and real workload differences

**Files:**
- Create: `Attic/Optics/OpticalMetalRenderer.swift`
- Create: `Attic/Optics/OpticalShaderLibrary.swift`
- Modify: `AtticTests/OpticalWorkloadTests.swift`
- Modify: `AtticTests/OpticalPerformanceMetricsTests.swift`

**Interfaces:**
- `final class OpticalMetalRenderer: NSObject, MTKViewDelegate` owns `MTLDevice`, command queue, pipeline, sampler, and `CVMetalTextureCache`.
- `func submit(frame: OpticalCaptureFrame, profile: OpticalGlassProfile, workload: OpticalWorkloadProfile, region: OpticalCaptureRegion)` retains only the latest frame and requests one draw.
- `func releaseResources()` clears frame/texture/cache references and pauses the view.
- Runtime shader uniforms include panel/capture geometry, squircle radius/exponent, independent visual axes, workload blur sample count, edge evaluation count, band, displacement, and interaction progress.

- [ ] Add renderer resource-state tests around a small pure `OpticalRendererLifecycle` before implementation.
- [ ] Compile a public Metal vertex/fragment library from a focused source string; no Core Image background filter or private filter key remains.
- [ ] Convert captured pixel buffers with `CVMetalTextureCache`; avoid CPU image copies.
- [ ] Make Low/Balanced/Maximum execute different capture dimensions, frame caps, queue depths, blur tap counts, and edge-evaluation paths.
- [ ] Make Refraction 0 return destination UV exactly and make the centre contribute zero displacement.
- [ ] Drive drawing from new frames; do not install an aggressive polling timer.
- [ ] Record render signposts, frame duration, drops, latency, and memory estimates without screen contents.
- [ ] Run CI and commit the renderer milestone.

### Task 6: AppKit backdrop integration and honest fallback

**Files:**
- Create: `Attic/Optics/OpticalPanelBackdropView.swift`
- Modify: `Attic/Window/AtticPanel.swift`
- Modify: `Attic/Window/AtticPanelController.swift`
- Modify: `Attic/App/AppCoordinator.swift`
- Modify: `Attic/Design/AtticStyle.swift`
- Delete implementation portions from: `Attic/Window/AtticPanel.swift` that define the Core Image/visual-effect filter backend.

**Interfaces:**
- `OpticalPanelBackdropView.update(controls:preset:cornerRadius:screen:panelFrame:)` updates pure profile/configuration.
- `setVisible(_:)` starts authorized enabled live optics or selects fallback; false always stops capture and releases renderer resources.
- `stop()` is idempotent and releases all optical resources.
- `respondToInteraction()` updates event-driven interaction state only.

- [ ] Add failing fallback/lifecycle integration assertions to pure coordinators before editing AppKit code.
- [ ] Reduce `AtticPanel.swift` to `NSPanel` behavior and interaction forwarding.
- [ ] Implement the backdrop view with sibling fallback and Metal views below the existing hosting view.
- [ ] Preserve transparent hosting view, mask, hit-test pass-through, sizing, reveal/hide animation, and all foreground behavior.
- [ ] Bind preset and independent controls; never bind focus/key state.
- [ ] Stop capture before hide animation, on Off, and in `AppCoordinator.stop()`; safely restart on reveal.
- [ ] Ensure unavailable/denied/error states show material or opaque fallback without a rim, static image, or simulated displacement.
- [ ] Run CI and commit the integration milestone.

### Task 7: Settings UI, adaptive environment, and permission action

**Files:**
- Create: `Attic/Optics/OpticalEnvironmentMonitor.swift`
- Modify: `Attic/Views/Settings/SettingsView.swift`
- Modify: `Attic/Window/SettingsWindowController.swift`
- Modify: `Attic/App/AppCoordinator.swift`
- Modify: `Attic/Window/AtticPanelController.swift`
- Modify: `AtticTests/OpticalAdaptiveQualityTests.swift`

**Interfaces:**
- `OpticalEnvironmentMonitor` emits notification-driven battery source, Low Power, thermal, and display-scale snapshots.
- Settings receives `OpticalPermissionController` and shows preset picker, approximate power copy, permission state, explicit request, and open-settings action.
- Advanced remains a `DisclosureGroup` with initial `false` state.

- [ ] Add tests for environment-to-adaptive-input mapping and verify focus is absent.
- [ ] Add the five performance choices with concise power descriptions and Balanced recommendation.
- [ ] Keep independent sliders visible for every preset; explain that Off preserves values but disables live optics.
- [ ] Add honest Screen Recording explanation and an explicit Enable Live Optics action; never request on appear/reveal.
- [ ] Implement notification-driven power/thermal monitoring and performance-window feedback into the adaptive controller.
- [ ] Ensure Adaptive effective-quality transitions reconfigure workload safely and obey hysteresis.
- [ ] Run CI and commit the settings/adaptive milestone.

### Task 8: Golden coverage, self-review, project verification, and final checks

**Files:**
- Create: `AtticTests/OpticalGeometryTests.swift`
- Modify: `AtticTests/AppSettingsTests.swift`
- Modify: `AtticTests/OpticalWorkloadTests.swift`
- Modify: `AtticTests/OpticalCaptureLifecycleTests.swift`
- Modify: `AtticTests/OpticalPerformanceMetricsTests.swift`
- Modify generated project only through: `Scripts/generate_project.rb` and `Scripts/verify_project_generation.rb` if generation requires a source-list change.

**Interfaces:**
- Synthetic grid/golden tests validate mathematical displacement signatures only.
- CI remains the repository-executable build/test/analyze authority; local UAT remains separate.

- [ ] Add/relocate continuous edge, zero centre, target envelope, scale, crop, overscan, and synthetic-grid tests.
- [ ] Self-review for centre seams, rectangular remnants, whole-panel stretch, foreground displacement, fake optics, focus coupling, capture recursion, stale generations, lifecycle leaks, and unbounded logging.
- [ ] Confirm no identifier, signing, entitlement, CloudKit/APNs, store, schema, sync, build-number, or mobile change appears in the base-to-head comparison.
- [ ] Run project-generation verification, Local build, strict-concurrency build, macOS unit tests, UI tests, and analyzer through CI.
- [ ] Fix every repository-executable failure with a test-first regression where applicable.
- [ ] Commit final verification fixes and record exact milestone SHAs.
- [ ] Report local Xcode build, explicit permission, multi-display/Spaces/protected-content, target-image visual comparison, power, thermal, frame-time, dropped-frame, latency, and memory UAT still required.
