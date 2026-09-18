---
name: Audit method lessons
description: What worked and what misled during the 2026-09-18 whole-app source audit; where the findings ledger lives.
---

# Whole-app audit (September 2026)

- The findings ledger, coverage matrix, disproved hypotheses, and macOS gate list are checked in at `Docs/Whole-App-Audit-2026-09-18.md` on branch `audit/whole-app-2026-09-18`. Read it before re-auditing; do not re-derive it.
- Delegated explorer passes are good at achieving line coverage and bad at judging framework contracts. Every candidate they raised needed a source re-read, and about half were wrong or mislocated: an AppKit `hitTest` "double conversion" (the argument is in superview space, so `convert(point, from: superview)` is correct), "negative" dimensions that are actually clamped to zero, an overflow attributed to the wrong file, and a cache-reuse "defect" that the source documents as a deliberate trade-off.

**Why:** the owner explicitly asked for evidence-based findings with disproved hypotheses listed; unverified explorer output would have produced false Medium findings.

**How to apply:** treat explorer reports as leads with line numbers, never as findings. Re-read the quoted lines, check the framework contract, and record rejected leads with the reason.

# Termination ordering decision

- Termination preparation must run every veto-capable step (note draft flush) before any irreversible one (cancelling Canvas imports, flushing view state). Successful `stop()` remains the final idempotent teardown.

**Why:** a vetoed quit previously discarded in-flight Canvas imports; the owner asked that this fix be preserved.

**How to apply:** any new step added to app termination goes in the veto phase if it can fail, otherwise after it.
