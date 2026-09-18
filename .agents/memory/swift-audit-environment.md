---
name: Swift audit environment limits
description: How to check Swift edits in this Linux repl (parse-only), and the working rules that follow for a macOS-only app.
---

# Swift on this repl: parse only, never build or test

- Nothing in this project can be compiled or run here: it is AppKit/SwiftUI/SwiftData with Xcode-only test targets.
- The only working syntax check is the Swift 5.8 wrapper called with a repaired PATH (the wrapper script shells out to `basename`, which is missing from its PATH when invoked as plain `swiftc`):
  `PATH="$(dirname "$(command -v basename)"):$PATH" /nix/store/zjvxna5czh4p3cz1yz9mdsz1z04d50r1-swift-wrapper-5.8/bin/swiftc -parse <files>`
  Plain `swiftc` fails. `-parse` proves syntax only, not types.
- `Scripts/verify_project_generation.rb` cannot run (xcodeproj gems absent); installing gems was out of scope for the audit and should stay so unless asked.

**Why:** the owner's audit brief forbids claiming compile/test success from inspection and forbids new dependencies; the platform simply lacks Xcode.

**How to apply:** keep any Swift change minimal and type-obvious; add tests only to existing test files (a new file would change the generated Xcode project); state "parsed, not compiled" in every handoff and list the macOS gates to run.
