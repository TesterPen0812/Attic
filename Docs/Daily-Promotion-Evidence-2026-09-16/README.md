# Daily promotion evidence — 2026-09-16

Migration scripts and comparison output are preserved under `migration/`.
They use disposable `/tmp/attic-promotion-migration-20260916` paths and never
read the official store. See the adjacent promotion-migration report for scope.
To reproduce after `/tmp` cleanup, copy the three source/script files there
and run `run-migration-gate.zsh` from the Attic checkout.

`local-tests/` retains all promotion test outcomes, including failures:
- Fresh build-for-testing exited 0 (quiet log).
- Persistence focus: 122 tests, zero failures.
- Full suite: 830 executed, four skipped, one task-performance threshold failure.
- Isolated task-performance suite: four passed.
- Full repeat: 830 executed, four skipped, three task-performance threshold failures.
- Independent isolated repeat: four tests, two performance threshold failures.

Test binaries had identical SHA-256 hashes to the earlier green candidate.
Timing varied broadly on the loaded host. This does not establish a code
regression, but local performance acceptance is inconclusive. No assertions
were weakened and failing results are not represented as passes. Hosted CI
results must be recorded separately before integration/promotion.
