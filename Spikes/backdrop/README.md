# Permission-free backdrop spike (11 November 2026)

This standalone `swiftc` probe checks public window metadata, desktop image
access, system appearance, and a cached render of its **own** glass view. No
Attic code is compiled or changed. It deliberately never requests Screen
Recording or Accessibility access, reads `kCGWindowName`, or captures any
other application's pixels.

On the Air, sync the repository to the **existing**
`~/Projects/attic/attic-air/.build/jobs/attic-px-iphone-taskselect` folder
(excluding `.build`, `.git` and secret files) and run:

```zsh
tmux -L sshjobs new-session -d -s backdrop-spike-11nov \
  '/bin/zsh ~/Projects/attic/attic-air/.build/jobs/attic-px-iphone-taskselect/Spikes/backdrop/air-job.zsh'
```

`air-job.zsh` takes the shared Air build slot, checks the free disk threshold,
builds a self-contained app with `-D ATTIC_LOCAL_ONLY`, and signs it ad hoc
with the identical `Attic/AtticNotesLocal.entitlements` used by local-only
Attic. The direct helper prints JSON to standard output in
`.build/backdrop-spike-run.log`. For an independent privacy-state check,
`air-job-open.zsh` rebuilds with a fresh bundle ID and starts the probe via
LaunchServices. The app writes JSON only inside **its own** sandbox; the
helper copies it to `.build/backdrop-spike/observations-launchservices.json`
and logs to `.build/backdrop-spike-open-run.log`. No Attic sandbox or data is
accessed.

The controlled backing windows belong to the probe. A window whose background
changes from black to white will retain the same Core Graphics window metadata.
The view-cache experiment uses `NSVisualEffectView`, so it cannot establish
what a WindowServer screenshot of SwiftUI Liquid Glass would contain. APIs that
could raise a screen-capture permission prompt are deliberately not invoked.
