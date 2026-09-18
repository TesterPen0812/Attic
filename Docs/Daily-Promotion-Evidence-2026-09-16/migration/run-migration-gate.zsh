#!/bin/zsh
set -euo pipefail
setopt PIPE_FAIL

readonly gate_root='/tmp/attic-promotion-migration-20260916'
cd "$gate_root"

./verify-schema-fields.rb | tee schema-property-comparison.txt

xcrun swiftc -O -parse-as-library MigrationGate.swift -o MigrationGate \
  2>&1 | tee compile.log
./MigrationGate 2>&1 | tee run.log

grep -qx 'MIGRATION_GATE=PASS' run.log
grep -qx 'original_seed_unchanged=true' run.log
grep -qx 'candidate_round_trip=true' run.log
grep -qx 'external_payloads_preserved=true' run.log
grep -qx 'image_backfill_preserved_replica_fields=true' run.log

print -- 'REPRODUCTION=PASS'
