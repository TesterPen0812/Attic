# Attic

A tiny native task and notes app for Mac that stays out of the way until you need it.

Attic lives in the menu bar and reveals a lightweight panel when the pointer rests in a chosen screen corner. Current development is macOS-first and local-first; the iPhone companion and CloudKit synchronization are deferred.

## Demo

![Attic showing In Progress and To do tasks](Media/attic-fullscreen-preview.png)

## Features

- Reveals from any screen corner after a configurable delay
- Global `Control–Option–Space` shortcut for creating a task
- Separate Tasks and Backlog scopes, with To do, In Progress and Done states
- Indented subtasks with inline entry, a completion count, and collapsible families
- None, Low, Medium and High priorities
- Local-first SwiftData persistence
- Automatic cleanup of completed tasks after the day changes
- Multi-display and full-screen Space support
- Configurable reveal and hide delays
- Optional translucent or solid panel
- Launch at login support
- Native menu bar app with no Dock icon
- Event-driven UI and low-overhead pointer sampling
- Built-in MCP server so local AI agents can read and update tasks

## Requirements

- macOS 14 or newer
- Xcode 16 or newer

## Build and run

For development, use `./script/build_and_run.sh` to build and launch an isolated
local preview. The Codex Run action uses this path and does not update the daily
app. See [Daily app and development previews](Docs/DailyApp.md) for deliberately
installing or updating `/Applications/Attic Daily.app` from a reviewed commit.

You can open `Attic.xcodeproj` in Xcode for source inspection. For Xcode-only
experiments, configure a unique preview bundle identifier and local-only
entitlements first; `com.taha.Attic` is reserved for the daily app. The preview
script handles that isolation automatically.

Choose a corner and reveal delay in Settings. Press `Control–Option–Space` from anywhere in macOS to reveal Attic with the new-task field focused.
Press `Command–,` while Attic is focused to open Settings.

## Deferred iPhone and CloudKit support

Current builds compile with `ATTIC_LOCAL_ONLY` and do not request CloudKit or
APNs entitlements. Existing synchronization code remains available for a future,
explicitly planned activation using a CloudKit container owned by Taha's Apple
developer account. Until that work is completed, local builds and tests are not
evidence of cross-device synchronization.

## Interactions

- Double-click a To do task to move it to In Progress.
- Double-click an In Progress task to move it back to To do.
- Click or double-click a Backlog idea to promote it to To do.
- Click the priority-colored circle to complete a task.
- Click the circle on a completed task to restore it.
- Drag tasks to reorder them within the same status and priority group.
- On iPhone, use the three-line handle to drag a task directly into another
  status section or onto another task.
- Drag a task into another app to insert its title as plain text.
- Use the trailing ellipsis to edit, move, reprioritize or delete a task.

### Subtasks and compact entry

Choose **Add subtask…** from a main task's ellipsis menu. Steps are saved inline,
remain indented when completed, and can be shown or hidden with the chevron.
The progress count stays visible while collapsed. Section totals count main
tasks only; moving a main task between Tasks and Backlog carries its family.
Subtasks support one level, their own title, status and priority, and reordering
within the same parent/status/priority group.

Complete the steps before completing their parent. Finishing the last step does
not complete the parent automatically. Reopen a completed parent before adding
or reopening a step. Deleting a parent asks for confirmation and deletes its
subtasks too; deleting one step leaves the rest intact. Automatic cleanup keeps
a family until every member is completed before the current local day and all
physical replicas agree. Existing tasks gain an empty optional parent link;
their identities and content are preserved by normal local schema migration.

The quick-entry composer stays one row tall while typing. Click **+** to reveal
the slim priority strip and **×** to collapse it without clearing the title or
priority. Return or the arrow saves the task. Unsaved subtask text survives
collapsing its family and switching sections during the current app session;
it is not a saved task until submitted.

## Agent access (MCP)

When Agent access is explicitly enabled, Attic serves the [Model Context Protocol](https://modelcontextprotocol.io) over Streamable HTTP at `http://127.0.0.1:7335/mcp`, loopback only. The feature is disabled by default and tool requests require the private bearer token provided by Settings → Agent Access → Copy setup prompt. Authorized clients such as Claude Code, Synara, Codex or Cursor can list, create, update, complete and delete tasks, and every change appears live in the panel. Change the port with `defaults write com.taha.Attic agentServerPort <port>`.

Local-only builds support authenticated local MCP without enabling CloudKit or
APNs. Each app bundle identity has its own cryptographically random 256-bit
credential in Keychain, so previews never reuse the daily app's token. Credential
generation, access, or persistence failures prevent the listener from starting;
there is no fixed or ephemeral fallback. Keep the token private. Do not grant
broader Keychain permissions just to automate connection setup.

Credential loading begins only when Agent Access is enabled and never blocks
the app's main thread. If macOS requires Keychain approval, the listener remains
closed until that succeeds. Turning access off while approval is pending keeps
the listener off. Both unit and UI test hosts use isolated ephemeral credentials.

Settings also provides **Copy setup prompt**, which creates a client-aware prompt containing the local endpoint and private bearer token. Paste it into Codex, Synara, or Claude to have that client configure or repair only its `attic` MCP entry and verify the connection.

Tools: `list_tasks`, `create_task`, `update_task` (set `status` to `done` to complete), `delete_task`. Statuses are `todo`, `inProgress`, `done`, `backlog`; priorities are `none`, `low`, `medium`, `high`.

`create_task` accepts optional `parent_id` (an unfinished main task UUID).
`list_tasks` returns main tasks and subtasks and accepts `parent_id` to list only
that parent's steps. Subtask results include `parent_id`; updates use the usual
task UUID. `delete_task` on a parent deletes its entire family, so clients must
include the children in the user's deletion scope.

Claude Code / Synara (available in every project via `--scope user`):

```sh
claude mcp add --transport http --scope user \
  --header "Authorization: Bearer <TOKEN FROM SETTINGS>" \
  attic http://127.0.0.1:7335/mcp
```

or in a project's `.mcp.json`:

```json
{
  "mcpServers": {
    "attic": {
      "type": "http",
      "url": "http://127.0.0.1:7335/mcp",
      "headers": {
        "Authorization": "Bearer <TOKEN FROM SETTINGS>"
      }
    }
  }
}
```

Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.attic]
url = "http://127.0.0.1:7335/mcp"
bearer_token_env_var = "ATTIC_MCP_TOKEN"
```

Set `ATTIC_MCP_TOKEN` to the token shown in Attic before starting Codex.

Older Codex builds without authenticated Streamable HTTP support must be updated before connecting to Attic.

For a read-only check with the official TypeScript MCP SDK, set
`ATTIC_MCP_SDK_ROOT` to an installed `@modelcontextprotocol/sdk` directory and
provide `ATTIC_MCP_TOKEN` privately in the process environment, then run
`node Scripts/verify_mcp_client.mjs`. `ATTIC_MCP_ENDPOINT` defaults to the endpoint
above and rejects non-loopback destinations. Alternatively, set
`ATTIC_MCP_BUNDLE_ID` to the intended app identity to request its Keychain item;
macOS may require interactive approval. The script never prints credentials or
task/note content. Its optional `--exercise-test-data` flag creates, completes,
verifies and deletes only a uniquely identified task family from that invocation.

The optional `AgentServerIntegrationTests/testOfficialMCPClientInteroperability`
gate starts the real listener on an ephemeral loopback port with an in-memory
store and runs the same SDK script in another process. Supply
`TEST_RUNNER_ATTIC_MCP_NODE` and `TEST_RUNNER_ATTIC_MCP_SDK_ROOT` to `xcodebuild`
to enable this gate; it is explicitly skipped when those dependencies are not
configured. The remaining native socket/authentication tests require no SDK.

## Tests

```sh
xcodebuild test \
  -project Attic.xcodeproj \
  -scheme Attic \
  -destination 'platform=macOS'

# Signed, isolated macOS UI tests. This runner acquires
# /tmp/attic-exclusive-ui.lock before driving the installed host.
Scripts/run_local_ui_tests.zsh

xcodebuild test \
  -project Attic.xcodeproj \
  -scheme AtticMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Project generation

`Scripts/generate_project.rb` atomically generates the Xcode project using the locked Ruby `xcodeproj` gem and stable UUIDs. Install the dependency with `bundle install`, then run `bundle exec ruby Scripts/generate_project.rb` after adding source files that need to be included in the project. Use `--help` to inspect the command without changing the project, or `--output PATH` to generate a separate copy.

Run `bundle exec ruby Scripts/verify_project_generation.rb` to confirm that two consecutive generations are identical.

## License

Attic is available under the [MIT License](LICENSE).
