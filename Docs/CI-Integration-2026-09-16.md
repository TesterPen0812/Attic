# CI integration — 16 September 2026

## Initial PR result

Pull request #3 first ran macOS CI as Actions run
[`35123967902`](https://github.com/TesterPen0812/Attic/actions/runs/35123967902).
Both aggregate jobs failed, and no gate was bypassed.

The macOS job ran on `macos-15`, which selected Xcode 16.4 and the macOS 15.5
SDK. Attic's current SwiftUI implementation uses the Xcode 26 Liquid Glass
surface (`Glass`, `glassEffect`, and `GlassEffectContainer`), so the app build,
strict-concurrency build, unit-test build, and analyzer could not compile on
that toolchain. The UI-test command also selected the `Attic` scheme even
though the generated `AtticUI` scheme owns `AtticUITests`.

The iPhone build reached Swift compilation but the generated mobile target did
not contain all shared dependencies. Errors included missing
`TaskImageReference`, `TaskImageFiles`, `TaskAttachmentStaging`,
`TaskAttachmentSource`, `NoteBodyEditBatch`, and the panel-theme environment
key. The repository development contract explicitly defers iPhone work and
says it is not a gate for macOS integration or a macOS-only release. This
failure is recorded, not reclassified as a pass.

Both jobs also reported a failed final-worktree assertion after project
generation verification passed. The original assertion captured
`git status --porcelain` inside a silent `test`, so the run did not reveal the
changed path.

## Workflow correction

The workflow now uses `macos-26` and pins `DEVELOPER_DIR` to the installed
Xcode 26.6 toolchain. GitHub's official runner-image inventory at commit
[`dff7cf5f`](https://github.com/actions/runner-images/commit/dff7cf5f1d89bdac4336cd261875e553582fe769)
lists `macos-26` as the ARM64 YAML label and Xcode 26.6 as its default, with a
macOS 26 SDK. The workflow also prints and asserts the Xcode and SDK major
versions before building.

The first Xcode 26 rerun, Actions run
[`35124798381`](https://github.com/TesterPen0812/Attic/actions/runs/35124798381),
confirmed that toolchain selection, project generation, and the corrected UI
scheme routing worked. It then exposed one app-source compiler blocker common
to the normal build, strict build, unit-test build, UI-test build, and analyzer:
Xcode 26.6 could not type-check the expression at
`Attic/Views/Panel/AtticPanelView.swift:234` in reasonable time. The workflow
kept every affected gate failed; this is a product-source issue rather than a
CI suppression candidate.

That rerun also identified the previously hidden cleanliness residue.
`ruby/setup-ruby`'s dependency cache created `.bundle/config` and
`vendor/bundle/` inside the checkout. Ruby setup now installs dependencies with
`BUNDLE_PATH` and `BUNDLE_USER_CONFIG` rooted under `RUNNER_TEMP`, preserving a
strictly clean checkout without ignoring generated files.

The macOS build, strict-concurrency build, unit tests, UI tests, analyzer, and
final cleanliness check remain required. UI tests now use `AtticUI`. Final
cleanliness failures print the complete porcelain status plus staged and
unstaged diffs before failing.

## Full Xcode 26 gate result

Pull-request run
[`35126949864`](https://github.com/TesterPen0812/Attic/actions/runs/35126949864)
completed every macOS gate. Project generation, the normal build, the
strict-concurrency build, and the static analyzer passed. The unit-test gate
reported 10 failures and the UI-test gate reported 13 failures; both remain
required failures while their source and test fixes are handled separately.

The final-worktree gate found one additional deterministic dependency change:
Bundler 4.0.11 added its own missing checksum to `Gemfile.lock`. The checksum,
`5bcec0fb78302e48d02ee46f10ee6e6942be647ba5b44a6d1ddfda9a240ce785`,
matches the SHA-256 digest of `bundler-4.0.11.gem` fetched directly from
RubyGems. It is now checked in, and CI sets `BUNDLE_FROZEN=true` so dependency
installation fails instead of modifying the lockfile.

Unit and UI `xcodebuild` invocations remain complete required suites. They now
have 20-minute and 30-minute step limits respectively; reaching either limit
fails that gate. CI uploads both test result bundles on success or failure so
crashes and test diagnostics are retained for seven days.

The deferred iPhone job no longer runs on pull requests or pushes. It is
available only through `workflow_dispatch` when the caller explicitly enables
the `run_iphone` boolean input. Its known target-membership errors remain open
until iPhone development is deliberately reactivated.

## Verification

- Workflow diff passed `git diff --check`.
- The workflow parsed as YAML locally.
- Pull-request run `35124798381` verified hosted Xcode 26 routing and exposed
  the app-source compiler blocker and dependency-cache residue above.
- Pull-request run `35126949864` passed project generation, the normal build,
  strict-concurrency build, and analyzer, then reported the required unit-test,
  UI-test, and final-worktree failures described above.
- Another real pull-request CI run is required after the combined source,
  test, lockfile, and workflow fixes are pushed.
