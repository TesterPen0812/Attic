# Daily app and development previews

The daily app is a deliberately installed, pinned macOS/local-only build. It is
not overwritten when developing or using the normal Codex Run action.

| | Daily app | Development |
|---|---|---|
| App | `/Applications/Attic Daily.app` | Isolated preview in the worktree build directory |
| Bundle identifier | `com.taha.Attic` | `com.taha.Attic.local.<worktree-token>` or another explicit preview identifier |
| Executable | `AtticDaily` | Unique preview executable |
| Data | Official sandbox, local `development.store` | Separate sandbox/store for each preview identity |
| Updates | Explicit clean-commit installation | `./script/build_and_run.sh` |

The original `/Applications/Attic.app` and former owner's container are not
modified. Existing notes in another app/preview are not silently transferred.
CloudKit, APNs, and the local agent server remain disabled, matching the current
local-only preview scope.

## Install or update the daily app

First validate the intended change in an isolated preview and run the relevant
tests. Commit the source, then deliberately promote that exact commit:

```sh
Scripts/install_daily_app.zsh --dry-run
Scripts/install_daily_app.zsh --install --expected-sha <full-reviewed-commit-sha>
```

The installer rejects dirty or mismatched source, retains the preview launcher's
official-identity guard, and uses the available Apple Development certificate
for team `ZGZWS73268`. It builds only `Local` with `ATTIC_LOCAL_ONLY` and
`ATTIC_DAILY`, explicitly uses sandbox/network-only entitlements, and pins the
store environment to `Development` so a future release configuration cannot
accidentally select `default.store`/the production store.

For an existing daily app, it requests a normal quit, backs up the app and its
Application Support/preferences/saved-window-state directories, stages and
validates the replacement, and preserves the same bundle identifier and data
paths. A source change during the build aborts installation. No force-kill,
automatic data migration, reset, or cloud activation is performed by the script.
SwiftData may perform normal schema migration on a future first launch; schema
changes therefore require explicit migration review and validation before promotion.

Release manifests, previous app/data backups, code signatures, and entitlements
are retained under `~/Library/Application Support/AtticDailyReleases/`. Each
installation also creates an immutable local `attic-daily-<build>-<commit>` tag.
The build number increments on each install. This is a local update workflow,
not an automatic internet updater or a published/notarized distribution.

Keep the latest backup. App rollback alone is not guaranteed to reverse a future
store-schema migration; restoring data requires a deliberate, reviewed recovery.

## Everyday use

Launch **Attic Daily** from Applications. It is a menu-bar app, not a Dock app.
Use the menu-bar icon, the configured screen corner, or Control–Option–Space.
Command–comma opens Settings. Launch at login can be enabled in Settings when
wanted; the installer does not change that preference.

Development remains in the source worktree. Source edits and normal preview
builds cannot update the installed daily binary. Do not use Xcode's unmodified
official identity for experiments; use the isolated Run script instead.

## Checks

```sh
ruby Scripts/test_install_daily_app.rb
ruby Scripts/test_launch_local_preview.rb
```

Installed-app launch, persistence and update checks are separate from build/unit
results. Local daily use does not establish iPhone, CloudKit, APNs, TestFlight,
Production, or public distribution readiness.
