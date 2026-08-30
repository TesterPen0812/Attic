# Attic

A tiny native task and notes app for Mac that stays out of the way until you need it.

Attic lives in the menu bar and reveals a lightweight panel when the pointer rests in a chosen screen corner. Current development is macOS-first and local-first; the iPhone companion and CloudKit synchronization are deferred.

## Demo

![Attic showing In Progress and To do tasks](Media/attic-fullscreen-preview.png)

## Features

- Reveals from any screen corner after a configurable delay
- Global `Control–Option–Space` shortcut for creating a task
- Separate Tasks and Backlog scopes, with To do, In Progress and Done states
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

1. Clone the repository.
2. Open `Attic.xcodeproj` in Xcode.
3. Select the `Attic` target and choose your development team under Signing & Capabilities.
4. Run the `Attic` scheme for Mac. The official bundle identifier is `com.taha.Attic`.

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

## Agent access (MCP)

When Agent access is explicitly enabled, Attic serves the [Model Context Protocol](https://modelcontextprotocol.io) over Streamable HTTP at `http://127.0.0.1:7335/mcp`, loopback only. The feature is disabled by default and every request must include the random bearer token shown under Settings → Agent access. Authorized clients such as Claude Code, Synara, Codex or Cursor can list, create, update, complete and delete tasks, and every change appears live in the panel. Change the port with `defaults write com.taha.Attic agentServerPort <port>`.

Settings also provides **Copy setup prompt**, which creates a client-aware prompt containing the local endpoint and private bearer token. Paste it into Codex, Synara, or Claude to have that client configure or repair only its `attic` MCP entry and verify the connection.

Tools: `list_tasks`, `create_task`, `update_task` (set `status` to `done` to complete), `delete_task`. Statuses are `todo`, `inProgress`, `done`, `backlog`; priorities are `none`, `low`, `medium`, `high`.

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

## Tests

```sh
xcodebuild test \
  -project Attic.xcodeproj \
  -scheme Attic \
  -destination 'platform=macOS'

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
