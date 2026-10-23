# Attic

Attic is a native macOS app for tasks and notes. It lives in the menu bar and
shows a floating panel when the pointer rests in a chosen screen corner, or
when you press `Control–Option–Space`.

Attic is macOS-first and local-first. Your data stays in a local SwiftData
store on the Mac. An iPhone app and CloudKit sync exist in the source but are
switched off (see [What is not active](#what-is-not-active)).

<p align="center">
  <img src="Media/attic-panel.png" width="375" alt="The Attic panel on the Notes page: a note titled “Woah” that says “This app is dope”, with a large image of a cigar-smoking emoji, and the pin, Notes, Aa and new-note buttons at the panel’s corners.">
</p>

## What works today

### The panel

- Reveals from a chosen screen corner after a set delay, or from the global
  shortcut with a new task ready to type.
- Three pages: **Tasks**, **Notes** and **Canvas**.
- Content scrolls under the floating controls and stays visible there, blurred.
- Glass or solid surfaces, palettes and tint, Light and Dark, and Reduce
  Transparency support.
- A menu bar app with no Dock icon. Launch at login is optional.

### Tasks

- Three tabs: **Now**, **Later** and **Done**. A task in Now is To do or In
  Progress.
- Priorities, due dates, tags, subtasks one level deep, and file and image
  attachments.
- Composers that grow as you type and accept attachments.
- Drag to reorder, drag tasks and files out to other apps.
- Finished tasks collect in Done, which has its own search.

### Notes

- A writing view, and an All notes library with search and tags shared with
  Tasks.
- A format bar, text styles and a `/` menu. Headings that fold, numbered
  lists, bullets and checklists, quotes, callouts, code blocks with on-device
  syntax colouring, tables, dividers, highlights, links and dates.
- Images, file cards and print.
- Block drag, marquee selection, Find, version history, recovery drafts, and
  review of changes made outside the app.
- Markdown paste and Copy as Markdown, built on Apple's
  [swift-markdown](https://github.com/swiftlang/swift-markdown).
- Rich paste (RTF, RTFD, HTML, web archives) keeps text, formatting, links and
  local images. Paste never fetches anything from the network; remote images
  are left out.

### Everywhere

- Deleting a task or its writing moves the whole item, including subtasks and files, to one Recently Deleted entry for 30 days. Restore returns its original placement. Old independent deletions remain separate.
- Recently Deleted keeps deleted items and canvases for 30 days.
- Settings: General, Panel, Appearance, Recently Deleted, Agent Access and
  About. `Command–,` opens it while Attic is focused.
- An optional local MCP server lets AI agents on the same Mac read and change
  tasks and notes (see [Agent access](#agent-access-mcp)). It is off by
  default.

## What is not active

- **iPhone app and CloudKit sync.** Builds compile with `ATTIC_LOCAL_ONLY`
  and request no CloudKit or APNs entitlements. The sync code stays dormant
  until a separate, planned activation. A local build or test passing is not
  evidence that sync works. The rules are in the Development Contract in
  [`AGENTS.md`](AGENTS.md).
- **Canvas.** The Canvas page is the pre-redesign implementation. It is kept as
  it is until it is rebuilt.

## Requirements

- macOS 26 or newer.
- Xcode 26.6 (the version CI uses).
- Ruby with Bundler, to generate the Xcode project. CI uses Ruby 3.3. Use a
  current Ruby, such as Homebrew's, rather than the macOS system Ruby.

## Build and run a local preview

1. Install the project generator's dependency and generate the project:

   ```sh
   bundle install
   bundle exec ruby Scripts/generate_project.rb
   bundle exec ruby Scripts/verify_project_generation.rb
   ```

   `Attic.xcodeproj` is checked in, but it is generated. Change
   `Scripts/generate_project.rb`, not the project, and regenerate after adding
   source files. The verify script checks that two generations are identical.

2. Build and launch an isolated preview:

   ```sh
   ./script/build_and_run.sh
   ```

   This builds the `Local` configuration with local-only entitlements under a
   bundle identifier unique to the checkout
   (`com.taha.Attic.local.<token>`), with its own sandbox and store. It never
   replaces an installed copy of Attic.

   For more control, call the launcher directly. `--help` lists every option.

   ```sh
   Scripts/launch_local_preview.zsh \
     --display-name 'Attic Preview' \
     --bundle-id com.taha.Attic.preview \
     --executable-name AtticPreview \
     --optimized
   ```

   `--optimized` builds with `-O`, which is what to use when judging speed or
   feel. `--verify` checks that the running preview is the build on disk.

`com.taha.Attic` is the identity of the everyday app. Do not run experiments
under it. [Docs/DailyApp.md](Docs/DailyApp.md) explains how the everyday app
is installed from a reviewed commit.

## Tests and CI

Run builds and tests through `Scripts/xcodebuild_locked.sh`, which takes a
machine-wide lock so parallel builds don't collide.

```sh
# Unit tests
Scripts/xcodebuild_locked.sh test -project Attic.xcodeproj -scheme Attic \
  -configuration Local -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO -only-testing:AtticTests

# Generated model, matrix, stress and Markdown round-trip tests
Scripts/xcodebuild_locked.sh test -project Attic.xcodeproj -scheme AtticRoundTrips \
  -configuration Local -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO -only-testing:AtticRoundTripTests

# UI tests (they drive a signed, installed host and take the screen)
Scripts/run_local_ui_tests.zsh
```

- **Invisible test host.** Unit tests run inside `AtticUnitTestHost`, which
  keeps every window off screen and never takes the keyboard, so tests can run
  while you work. A canary fails any test after which the host is active or
  has a window on a display. Tests that
  need a real key window opt in with `TEST_RUNNER_ATTIC_KEY_WINDOW_TESTS=1`;
  CI sets it.
- **Generated round trips.** Long generated tests (editing sequences, models,
  matrices, stress and Markdown round trips) live in the `AtticRoundTripTests`
  bundle. `Scripts/generated_test_routes.json` lists which test methods move
  there, and the project generator compiles each method into exactly one
  bundle.
- **CI** is [`.github/workflows/macos-ci.yml`](.github/workflows/macos-ci.yml)
  ("Attic CI"). It runs on pull requests and on pushes to `main`, using the
  `full` lane. A manual run picks a lane:
  - `fast`: builds, runs the unit tests and the generated round trips in
    parallel, the static analyzer, and the project-generation checks. Timing
    gates report but don't block.
  - `full` (the default): everything in `fast`, plus UI tests, Full Keyboard
    Access tests, the optimized cost gates with the heavy retention soaks,
    seeded performance runs and the design-system appearance matrix.
  - `costs` and `fka` run just those jobs. The iPhone build runs only when
    asked for (`run_iphone`).

The heavy retention soaks are skipped locally unless
`TEST_RUNNER_ATTIC_SOAK_TESTS=1` is set. The full appearance matrix and its
contact sheets run locally with `Scripts/run_appearance_matrix.zsh`.

## Agent access (MCP)

When Agent Access is turned on in Settings, Attic serves the
[Model Context Protocol](https://modelcontextprotocol.io) over Streamable HTTP
at `http://127.0.0.1:7335/mcp`, on loopback only. Every request needs a bearer
token. Each app identity has its own random 256-bit token in the Keychain; if
the token can't be created or read, the server doesn't start. Settings →
Agent Access → **Copy setup prompt** gives a prompt with the endpoint and
token for Claude Code, Codex, Cursor and similar clients. Keep the token
private. Change the port with
`defaults write com.taha.Attic agentServerPort <port>`.

The tools cover tasks and subtasks, notes (including tables), tags, links,
Recently Deleted, settings, and showing an item in the panel. Each tool
describes its arguments in `tools/list`. A few rules:

- Writes to a note pass the `revision` from `list_notes` as `base_revision`.
  A change to a note that is open on screen waits as a proposal the person
  reviews; the reply has `status: "pending"`.
- Task-note writes also pass `note_token` and `association_token` from
  `get_task_workspace` as `base_note_token` and `base_association_token`.
  These cover every physical replica and expected absence. A stale workspace
  write is kept as a proposal requiring review.
- The async workspace tools `make_subtask`, `make_note_checkbox`,
  `make_task_from_note`, `restore` (notes), and `move_files_into_note` require
  `base_workspace_token`: paired Delete/Restore aliases also require this combined token and run as one whole-item change (a stale or open-editor call becomes one proposal). Pass the combined `workspace_token` returned by
  `get_task_workspace`, or request it with `include_workspace_token: true`
  in `list_notes` or `list_deleted`. This token covers the complete read set
  from one snapshot. Open-editor or stale writes wait as proposals for Review.
- Deleting moves items to Recently Deleted. Agents can't delete anything
  permanently. Deleting a task takes its subtasks with it.

Claude Code:

```sh
claude mcp add --transport http --scope user \
  --header "Authorization: Bearer <TOKEN FROM SETTINGS>" \
  attic http://127.0.0.1:7335/mcp
```

Codex, in `~/.codex/config.toml`, with the token in `ATTIC_MCP_TOKEN`:

```toml
[mcp_servers.attic]
url = "http://127.0.0.1:7335/mcp"
bearer_token_env_var = "ATTIC_MCP_TOKEN"
```

`Scripts/verify_mcp_client.mjs` checks a running server with the official
TypeScript MCP SDK, read-only by default. The optional
`AgentServerIntegrationTests/testOfficialMCPClientInteroperability` test runs
the same check against a test server when `TEST_RUNNER_ATTIC_MCP_NODE` and
`TEST_RUNNER_ATTIC_MCP_SDK_ROOT` are set; otherwise it is skipped.

## Repository layout

| Path | What it holds |
|---|---|
| `Attic/` | The macOS app: `App`, `Window` and `Views` (the panel and Settings), `Tasks`, `Notes`, `Canvas`, `Models`, `Services` (storage, MCP server, appearance), `DesignSystem` and `Design`. |
| `AtticTests/` | Unit tests, and the sources of the generated round-trip bundle. |
| `AtticUITests/` | macOS UI tests. |
| `AtticUnitTestHost/` | The invisible host app that unit tests run in. |
| `AtticMobile*/` | The dormant iPhone app and its tests. |
| `Scripts/` | Project generation, the preview launcher, test and CI helpers, and performance tools. |
| `script/build_and_run.sh` | One-step preview build and launch. |
| `Docs/` | The few documents that still govern current work; see [Docs/README.md](Docs/README.md). |
| `AGENTS.md`, `claude.md` | Instructions for coding agents, including the Development Contract. |

Design-system changes are logged in
[`Attic/DesignSystem/CHANGELOG.md`](Attic/DesignSystem/CHANGELOG.md).

## Third-party code

Attic uses Apple's [swift-markdown](https://github.com/swiftlang/swift-markdown)
0.9.0, under the Apache License 2.0 with the Swift Runtime Library Exception,
and [swift-cmark](https://github.com/swiftlang/swift-cmark) 0.9.0, a
cmark-gfm derivative under a BSD-style licence with notices for its bundled
components. Versions are pinned in
`Attic.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Their licences and notices ship in the app as
[`Attic/Resources/ThirdPartyNotices.txt`](Attic/Resources/ThirdPartyNotices.txt).

## Licence and credits

Attic is available under the [MIT License](LICENSE). It was created by
Emanuele Di Pietro, who holds the copyright named in the licence. This
repository continues that work.
