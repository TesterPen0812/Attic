#!/usr/bin/env python3
"""Install OD-6's assertion policy into the pinned historical test fixtures.

Do not copy today's fixtures: historical measurement boundaries must stay intact.
Exact replacements fail closed if the pinned tests change. App sources and
correctness assertions are untouched; no Xcode project input is added.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
BEGIN = "// BEGIN COST BUDGET POLICY"
END = "// END COST BUDGET POLICY"
REPLACEMENTS = {
    "TasksFrameCostTests.swift": [
        ("XCTAssertLessThan(Self.median(keys), 500)", "CostBudget.assertLessThan(Self.median(keys), 500)"),
    ],
    "DoneSearchCostTests.swift": [
        ('XCTAssertLessThanOrEqual(samples.last!, 16, "Done query exceeded the 16 ms budget")',
         'CostBudget.assertLessThanOrEqual(samples.last!, 16, "Done query exceeded the 16 ms budget")'),
        ('XCTAssertLessThanOrEqual(indexedMS, 16, "disk-backed Phase 5 Done query exceeded the spec\'s budget")',
         'CostBudget.assertLessThanOrEqual(indexedMS, 16, "disk-backed Phase 5 Done query exceeded the spec\'s budget")'),
    ],
}


def policy():
    source = (ROOT / "AtticTests/TasksFrameCostTests.swift").read_text()
    return BEGIN + source.split(BEGIN, 1)[1].split(END, 1)[0] + END + "\n"


def prepare(directory, fixture):
    names = ["TasksFrameCostTests.swift"]
    if fixture == "done":
        names.append("DoneSearchCostTests.swift")
    updated = {}
    for name in names:
        path = directory / "AtticTests" / name
        source = path.read_text()
        for old, new in REPLACEMENTS[name]:
            if source.count(old) != 1:
                raise ValueError(f"{path}: expected exactly one historical assertion: {old}")
            source = source.replace(old, new)
        if name == "TasksFrameCostTests.swift":
            source += "\n" + policy()
        updated[path] = source
    for path, source in updated.items():
        path.write_text(source)
        print(f"OD-6 reference assertion adapter: {path}")


if __name__ == "__main__":
    directory, fixture = sys.argv[1:]
    if fixture not in ("frame-row", "done"):
        raise ValueError("expected frame-row or done")
    prepare(Path(directory), fixture)
