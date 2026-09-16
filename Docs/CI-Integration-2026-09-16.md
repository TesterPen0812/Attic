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

The macOS build, strict-concurrency build, unit tests, UI tests, analyzer, and
final cleanliness check remain required. UI tests now use `AtticUI`. Final
cleanliness failures print the complete porcelain status plus staged and
unstaged diffs before failing.

The deferred iPhone job no longer runs on pull requests or pushes. It is
available only through `workflow_dispatch` when the caller explicitly enables
the `run_iphone` boolean input. Its known target-membership errors remain open
until iPhone development is deliberately reactivated.

## Verification

- Workflow diff passed `git diff --check`.
- The workflow parsed as YAML locally.
- A real pull-request CI rerun is required to validate the hosted runner,
  build, tests, analyzer, UI-test scheme, and exact final-worktree state.
