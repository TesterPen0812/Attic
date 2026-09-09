# MCP repair validation — 2026-09-09

## Scope and implementation

Source branch: `codex/attic-mcp-subtasks-composer`, starting at `2b5a066`.

- Removed the fixed local-only/test bearer-token bootstrap.
- Daily and preview identities use separate Keychain service names derived
  from their bundle identifiers. Credentials use 32 cryptographically random
  bytes encoded as URL-safe base64.
- Missing identity, invalid stored credentials, random generation failure,
  and Keychain read/write errors fail closed. No ephemeral persistence fallback.
- The listener rejects invalid credentials before creating its socket.
- Explicit opt-in, IPv4 loopback binding, bearer authentication, and browser
  Origin rejection remain intact. Malformed loopback Host values are rejected.
- Setup-prompt copying is disabled if a private credential is unavailable.
- Removed a redundant accessibility label override on the selectable endpoint
  that caused recursive accessibility resolution in the signed macOS preview.
- The unit host retains sandboxing and now uses the app's existing network-only
  entitlements so socket-level tests can run.

## Evidence

All paths below are relative to this worktree's `.build/evidence/` directory.

- `mcp-focused-1.xcresult`: 47 passed, 3 failed. The unit host lacked network
  entitlements; the actual listener reported Operation not permitted.
- `mcp-focused-2.xcresult`: all 50 passed after matching the host's permissions
  to the app, no skipped tests or runtime warnings.
- `mcp-full-1.xcresult`: all 559 tests passed before the added SDK gate.
- `mcp-sdk-1.xcresult`: official MCP TypeScript SDK 1.29.0 passed in a separate
  Node process against the real Swift listener with an in-memory test store.
  It verified initialization, task/note tool discovery and reads, task create /
  complete / observe after client reconnect, and deletion of its own test task.
  Missing, wrong, and old placeholder tokens returned 401; browser Origin
  returned 403. No real user data or Keychain credential was used in this gate.
- `mcp-settings-ui-1.xcresult`: native UI test passed opening and inspecting
  Agent Access connection details, checking copy controls, and disabling access.
- `mcp-full-2.xcresult`: **560 passed, zero failed/skipped, no runtime warnings**,
  with the external SDK gate enabled.
- Installer: 10 tests / 64 assertions passed. Preview launcher: 7 tests /
  54 assertions passed. Project generation was regenerated and verified repeatable.

The signed native preview is:

- Executable: `/Users/taha/Developer/attic-scroll-under-controls/.build/MCPPreview/Build/Products/Local/AtticMCPPreview.app/Contents/MacOS/AtticMCPPreview`
- Bundle: `com.taha.Attic.mcp20260909.preview`
- Display name: `Attic MCP Preview`
- Local signing override: `AQ484LXN59` (previously approved by the user).
- Build logs: `mcp-preview-build-1.log` and `mcp-preview-build-2.log`.

The preview was built from the working changes on baseline `2b5a066`, not from
an immutable final release commit. It started a listener verified at
`127.0.0.1:7335` only, and retained its own credential across a normal restart.
The enabled connection page was inspected visually and through accessibility
after the label fix, without displaying the token. Before the fix, accessibility
inspection caused a stack-overflow crash recorded in
`~/Library/Logs/DiagnosticReports/AtticMCPPreview-2026-09-09-221130.ips`.

## Boundaries and remaining installed-client check

The direct external-client attempt against the preview's own Keychain credential
stopped before connecting because macOS Keychain approval was unavailable to
automation. No Keychain permissions were broadened. This is separate from the
passing real-server SDK interoperability gate described above. No Codex,
Claude, Cursor, or Synara configuration was changed, and no claim is made that
one of those installed clients connected to the daily app in this verification.

The initial daily release is not updated merely by this source repair; promote
a reviewed clean commit with the protected daily installer before enabling its
MCP listener. Credential transfer into a trusted client still requires the app's
normal setup-prompt flow or the user's macOS approval. CloudKit, APNs, iPhone,
public distribution, and production-store behavior remain out of scope.
