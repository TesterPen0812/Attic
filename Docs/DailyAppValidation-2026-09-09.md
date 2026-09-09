# Daily installation and MCP validation — 2026-09-09

## Installed daily app

- App: `/Applications/Attic Daily.app`
- Executable: `/Applications/Attic Daily.app/Contents/MacOS/AtticDaily`
- Bundle identifier: `com.taha.Attic`
- Version/build: `1.1` / `1`
- Source branch: `codex/attic-scroll-under-controls`
- Installed source commit: `8b03586df79c6d667a6aea444b74f7167e552568`
- Release tag: `attic-daily-1-8b03586df79c`
- Configuration: `Local`, `ATTIC_LOCAL_ONLY` and `ATTIC_DAILY`
- Signing team: user-approved local override `AQ484LXN59`; project default remains `ZGZWS73268`.
- Store: official sandbox's local `development.store`, not a production or former-owner store.
- Release manifest and pre-install preferences backup:
  `/Users/taha/Library/Application Support/AtticDailyReleases/release-8b03586df79c-nN4AYq`

The protected installer requires a clean, exact source commit; verifies signed
identity and local-only entitlements; and retains a backup before replacing an
existing daily app. Ordinary development launches remain isolated previews and
do not overwrite this installation. The original Attic app, former-owner data,
and preview stores were not copied or altered. Launch at login was not enabled.

## Verification actually completed

- Installer checks: 10 tests / 64 assertions passed.
- Preview-launcher checks: 7 tests / 54 assertions passed.
- Full macOS/local unit suite: 548 passed, zero failed or skipped, no runtime
  warnings. Evidence: `.build/evidence/daily-unit-1.xcresult`. This ran on
  `acea8d7`; the subsequent installed commit changed only the installer,
  installer tests and documentation, not the Swift application code.
- Signed installation succeeded: `.build/evidence/daily-install-2.log`.
- Installed bundle passed `codesign --verify --deep --strict`.
- App opened as the exact installed executable.
- Native persistence check: created one task, **Welcome to Attic Daily**,
  through the real quick-entry control. Quit normally through the app menu,
  confirmed the old process exited, reopened the installed app, and verified
  the same task UUID `A45B3BEC-98D8-4B73-86E1-18C0C04F6073` and title remained.
  This welcome task is intentionally left in the daily store.

The installed restart check covered a task, not a saved note. Note-specific
persistence and draft coverage comes from the unit suite and earlier isolated
preview UI tests, not a new installed-daily note restart test. Physical gestures,
VoiceOver, a future update/rollback with existing daily data, and long-running
daily use remain unverified. This is local development signing, not a
notarized/public distribution or proof of deferred iPhone/cloud functionality.

## MCP result: not ready for agent connections

The installed preference `isAgentAccessEnabled` was `false`. There was no TCP
listener on port 7335 before or after the restart. A direct request to
`http://127.0.0.1:7335/mcp` failed with connection refused (curl exit 7, no HTTP
response). No Attic connector was available to this Codex task. No client
configuration or credentials were changed and the server was not enabled.

The full suite includes **39 passing HTTP/MCP tests**: 11 in
`AgentHTTPRequestTests` and 28 in `MCPRequestHandlerTests`. They cover parsing,
bearer/Host checks, initialize/version negotiation, notifications, tool
discovery, task/note operations, and invalid inputs in the test harness. They
do not use a real agent client or exercise a live socket listener.

### Blocking authentication finding

`AppCoordinator.swift:264–267` replaces the token with a fixed public placeholder
for every `ATTIC_LOCAL_ONLY` build. However, `AppCoordinator.swift:343–347`
observes the Agent Access preference and starts the server when enabled, with
no local-only guard. `AgentAccessSettingsView` also leaves that toggle available.
The comment that local-only previews keep MCP disabled is therefore not an
enforced safety boundary. If enabled, the server would accept the predictable
placeholder instead of a private random credential.

Keep Agent Access off. A follow-up implementation must secure credential
creation and isolation, preserve opt-in and loopback-only binding, and then
test live authenticated initialization, tool listing/read access, unauthorized
and browser-origin rejection, and post-restart reconnect with a real MCP
client. Mutation verification should use only explicitly created test data.
No claim is made that Codex, Claude Code, Cursor, or Synara connected to the
installed daily app during this check.
