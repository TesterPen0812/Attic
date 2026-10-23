#!/usr/bin/env python3
"""Audit the bounded 'Owner decision 2026-10-23' citations for slices A/B."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
# These are the owner answers quoted by this implementation. Draft B's
# separate layout approval is outside this slice A/B attribution audit.
ALLOWED = {
    ("AtticTests/TaskLifecycleSliceTests.swift", "the command is Add to Tasks."),
    ("Attic/Workspace/WorkspaceRestoreNormalization.swift", "Remove from Tasks drops task-only"),
}
failures = []
seen = set()
for folder in ("Attic", "AtticTests"):
    for path in sorted((ROOT / folder).rglob("*.swift")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if re.search(r"owner decision 2026-10-23", line, re.I):
                citation = line.split("2026-10-23", 1)[1].removeprefix(":").strip()
                key = (str(path.relative_to(ROOT)), citation)
                if key not in ALLOWED:
                    failures.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
                seen.add(key)
for missing in sorted(ALLOWED - seen):
    failures.append(f"Missing supported owner citation: {missing}")
if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
print("Slice A/B owner citations match the bounded owner answers.")
