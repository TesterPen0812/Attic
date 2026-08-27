# Custom Optical Glass Design

## Status and branch contract

This design implements the approved custom optical layer on `experiment/custom-optical-glass`. The branch merge base is `4c131e68437b857c8a5b97e365bcf84419de4f4e`. `main` is never modified. The implementation does not copy code from `squircle-panel`, `synara/adjust-panel-translucency`, or the native-glass branch.

The branch advanced to `939498af3610798b07a42eeeea919a86da4b08fc` before this design was committed. Those commits added a Core Image filter to an `NSVisualEffectView`. That path is not the approved architecture because public `NSVisualEffectView` contracts do not expose a programmable live desktop texture with explicit capture workload, permission, lifecycle, or performance control. Compatible pure optical math and settings tests may be retained, but the backdrop backend is replaced by ScreenCaptureKit plus Metal.

All Tasks, Backlog, Notes, drag/drop, keyboard focus, accepted squircle geometry, 10–140 pt radius, 300–380 pt width, adaptive insets, mask, disabled rectangular system shadow, and hit region remain unchanged. The foreground `NSHostingView` is never sampled or displaced.

## Public API feasibility

The primary source is ScreenCaptureKit. `SCShareableContent`, `SCContentFilter`, `SCStreamConfiguration`, and `SCStream` publicly support live display capture, application exclusion, source-region configuration, queue depth, frame interval, and pixel buffers suitable for GPU processing. Attic excludes its own running application to prevent recursive capture. A Metal renderer receives the captured `CVPixelBuffer` through `CVMetalTextureCache` and performs the optical remap.

Screen Recording permission is requested only after an explicit Settings action. `CGPreflightScreenCaptureAccess` reports current access and `CGRequestScreenCaptureAccess` performs the user-initiated request. `NSScreenCaptureUsageDescription` explains why Attic needs the permission. Denial, protected content, missing frames, unavailable ScreenCaptureKit, or unavailable Metal select an honest native material/opaque fallback. The fallback never draws a fake refractive rim and never uses a static screenshot.

No private WindowServer API, undocumented filter key, static wallpaper image, cached desktop image, or whole-panel foreground capture is used.

## View hierarchy and ownership

`AtticPanelController` owns a transparent AppKit container:

```text
PanelSurfaceContainerView
├── OpticalPanelBackdropView
│   ├── Native material/opaque fallback
│   └── Metal optical view (active only with authorized live capture)
└── NSHostingView<AtticPanelView>
```

The backdrop view returns `nil` from hit testing. The SwiftUI host remains the only interactive foreground. The accepted SwiftUI squircle clip remains authoritative for foreground content; the backdrop uses the same shared geometry for its alpha mask and optical edge field.

## Files and boundaries

- `Attic/Optics/OpticalGlassModels.swift`: controls, performance presets, concrete workload profiles, resolved visual profile, and fallback decisions.
- `Attic/Optics/OpticalGeometry.swift`: continuous squircle perimeter sampling, source-region mapping, overscan, and synthetic-grid signatures.
- `Attic/Optics/OpticalAdaptiveQuality.swift`: pure adaptive state machine and hysteresis.
- `Attic/Optics/OpticalPermissionController.swift`: explicit permission state and request/open-settings actions.
- `Attic/Optics/OpticalCaptureSession.swift`: ScreenCaptureKit stream ownership, self-exclusion, crop/update/start/stop, frame delivery, and generation rejection.
- `Attic/Optics/OpticalMetalRenderer.swift`: `MTKView`, texture cache, runtime-compiled public Metal shader, rendering, and resource release.
- `Attic/Optics/OpticalPerformanceMetrics.swift`: aggregate timing, dropped-frame, latency, and memory counters without screen contents.
- `Attic/Optics/OpticalPanelBackdropView.swift`: AppKit composition, fallback switching, capture/renderer coordination, visibility, interaction, and workload changes.
- `Attic/Window/AtticPanel.swift`: panel behavior and interaction forwarding only.
- Existing settings, controller, coordinator, style, Info.plist, and tests receive focused integration changes.

## User controls

Primary controls remain independent `0...100` values:

- Transparency changes transmission/base surface opacity only.
- Frost changes blur radius only.
- Refraction changes perimeter band and displacement only.

Advanced controls remain collapsed by default:

- Edge shine changes a broad normal-derived highlight, not a stroked outline.
- Tint changes chromatic contribution only.
- Readability changes the neutral centre support veil only.
- Interaction response changes a brief event-driven displacement multiplier only; the resting profile is unchanged.

Window focus is not an input to profile resolution, capture policy, or adaptive quality.

## Performance presets

`OpticalPerformancePreset` is persisted as `off`, `low`, `balanced`, `maximum`, or `adaptive`. Balanced is the default for new and existing optical installations unless a legacy opaque preference is the only prior glass setting, in which case it migrates to Off and zero transparency.

Every non-Off preset maps to a concrete workload rather than an opacity variation:

| Preset | Capture scale | Frame cap | Queue depth | Blur samples | Edge evaluations | Maximum band | Maximum displacement |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Off | 0 | 0 | 0 | 0 | 0 | 0 px | 0 px |
| Low | 0.50 | 15 fps | 2 | 5 | 1 | 28 px | 12 px |
| Balanced | 0.75 | 30 fps | 3 | 9 | 3 | 32 px | 19 px |
| Maximum | 1.00 | 60 fps | 5 | 13 | 5 | 36 px | 24 px |

The user’s Transparency, Frost, Refraction, and Advanced values are preserved when changing presets. A preset limits sampling quality and maximum optical envelope; it does not rewrite the controls. Refraction 0 always resolves to exactly zero band and zero displacement.

Off immediately stops ScreenCaptureKit, detaches outputs, clears pixel buffers and textures, releases the Metal texture cache and command resources owned by the backdrop, and displays only the lightweight fallback. Hiding the panel performs the same capture/GPU stop. Revealing safely creates a fresh generation and starts only when the selected/effective workload allows capture and permission is authorized.

## Adaptive quality

Adaptive resolves to Off while hidden and otherwise chooses Low, Balanced, or Maximum from event-driven inputs:

- Low Power Mode and serious/critical thermal pressure force Low.
- Battery power, display backing scale, and current thermal state set the initial ceiling.
- A scale above 2.0 prevents Maximum; a scale above 3.0 initially selects Low.
- AC power, nominal thermal state, scale at or below 2.0, and sustained healthy rendering may select Maximum.
- Sustained frame time, dropped-frame rate, and capture latency can degrade quality.

Hysteresis prevents oscillation. Severe environment changes degrade immediately. Performance degradation requires three consecutive unhealthy metric windows. Upgrade requires six consecutive healthy windows and at least twenty seconds since the last downgrade. Focus changes are deliberately absent from `OpticalAdaptiveInputs`.

Power/thermal changes are notification-driven. Performance decisions are driven by aggregate frame windows. There is no aggressive polling.

## Capture lifecycle

The capture state machine is deterministic and generation-based:

```text
stopped -> starting(generation) -> running(generation) -> stopping -> stopped
```

A start is allowed only when the panel is visible, workload allows capture, permission is authorized, a matching display exists, and Metal is available. Repeated starts for the same configuration are ignored. Geometry or workload changes update/restart through a fresh generation. Frames from previous generations are discarded.

The source rectangle is the panel frame expanded by optical overscan and clamped to the active display. Coordinate conversion is centralized and tested, including AppKit bottom-left to ScreenCaptureKit top-left mapping and Retina scaling. Overscan includes maximum displacement, frost radius, and a safety margin so sampling does not expose rectangular remnants.

`stop()` removes the stream output, stops capture, clears retained pixel buffers, and drops stream/filter/configuration references. The renderer clears drawable state and texture references. Capture never continues while the panel is hidden.

## Metal optical pipeline

The renderer is frame-driven rather than continuously polling. A new complete capture frame marks the `MTKView` for drawing. The runtime-compiled Metal fragment shader:

1. Evaluates the shared squircle boundary.
2. Returns identity coordinates when Refraction is 0 or the fragment lies outside the perimeter band.
3. Applies a smooth continuous edge influence with no separate left/right centre split.
4. Adds bottom and corner weighting, capped by the active workload envelope.
5. Samples the live captured texture using workload-specific capture scale and displacement complexity.
6. Applies Frost using a workload-capped number of samples.
7. Composites independent transparency, tint, readability, and normal-derived edge shine.
8. Alpha-masks the output to the squircle.

Maximum plus Refraction 100 targets a persistent 36 px band and up to 24 px bottom/corner displacement. Balanced targets a persistent 32 px band and approximately 19 px maximum. Low retains a subtle stable effect with lower resolution, update rate, queue depth, blur taps, and edge evaluations.

## Fallback matrix

- Performance Off: native material, or opaque semantic surface when Reduce Transparency is enabled.
- Permission not requested: native material plus explicit Settings action; no system prompt on reveal.
- Permission denied: native material and an Open Screen Recording Settings action.
- Capture unavailable, no matching display, protected/incomplete frame, or stream failure: native material for the current reveal and a bounded diagnostic state.
- Metal unavailable or shader compilation fails: native material; ScreenCaptureKit is not started.
- Reduce Transparency: opaque semantic surface and no custom optical capture.

Fallback state never changes task/note functionality, focus behavior, content geometry, or hit testing.

## Performance instrumentation and privacy

`OpticalPerformanceMetrics` records aggregate values only:

- rendered frame time and rolling mean/p95 estimate;
- captured, rendered, incomplete, and dropped frame counts;
- dropped-frame rate;
- capture-to-arrival latency;
- estimated pixel-buffer/texture memory from dimensions, bytes per pixel, and queue depth;
- selected preset and effective workload transitions.

Unified logging uses an `OpticalGlass` category and public numeric/profile fields only. Signposts cover capture start/stop and render duration. No pixel values, image hashes, OCR, window titles, task/note content, or screen contents are logged or persisted.

## Deterministic validation

Unit tests cover:

- settings persistence, clamping, legacy migration, and preset migration;
- independent control axes and focus invariance;
- exact Refraction 0 identity;
- concrete workload differences for all presets;
- adaptive initial selection, severe degradation, metric degradation, upgrade hysteresis, visibility, scale, battery, Low Power Mode, and thermal transitions;
- continuous perimeter mask, zero centre contribution, target envelopes, overscan, crop mapping, and synthetic-grid signatures;
- capture generation, duplicate-start suppression, stop/release commands, stale-frame rejection, and hidden/off behavior;
- fallback decisions for permission, capture, Metal, and accessibility states;
- aggregate performance metrics without screen data.

Source tests and synthetic goldens validate optical math, not live macOS composition. Local UAT remains mandatory for permission prompts, real desktop sampling, Spaces, protected content, multiple displays, visual match, power, memory, and frame performance.

## Explicit non-goals

This work does not modify identifiers, signing, entitlements, CloudKit/APNs, stores, SwiftData schema, sync, production data, build numbers, release configuration, or mobile behavior. It does not create a PR, merge, install, upload, deploy a schema, or release an app.
