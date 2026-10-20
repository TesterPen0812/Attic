#!/usr/bin/env python3
"""Adapt test-only fixtures for pinned cost hosts without changing their apps.

Frame/row and Done fixtures keep their historical measurement boundaries.
The integration host receives today's measured methods and their helpers,
retaining its historical functional tests rather than compiling new APIs.
Exact replacements fail closed if the pinned tests change. App sources and
correctness assertions are untouched; no Xcode project input is added.
"""
from pathlib import Path
import re
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

# Only these members participate in the integration measurements. Keep their
# bodies byte-identical on both sides, including every functional assertion.
# Other tests belong to their matching app revision, not the cost overlay.
INTEGRATION_MEMBERS = {
    "NotesPageControllerTests.swift": (
        "setUp", "tearDown", "makeController", "type", "realImage",
        "testMeasuredMainActorSaveOnFiveThousandLineNote",
        "testCheckpointRetirementKeepsMainActorWithinSaveTolerance",
        "assertSaveBaseline",
        "testMeasuredMainActorSaveIsIndependentOfUnrelatedStoreContents",
        "populatePerformanceStore", "SavePerformanceFixture",
        "makeSavePerformanceFixture", "measureMainActorSave",
    ),
    "NoteSlice3bTests.swift": (
        "testR9AccessibilityValidationStaysResponsiveWithStoredPayloadsAndActiveImport",
    ),
}


def member(source, name):
    """Find one four-space-indented Swift member, failing closed on drift.

    These fixture methods end with a four-space closing brace; nested bodies
    are indented further. No brace counting through Swift string literals.
    """
    matches = list(re.finditer(
        rf"^    (?:(?:private|override) )?(func|typealias) {re.escape(name)}\b[^\n]*", source, re.M))
    if len(matches) != 1:
        raise ValueError(f"expected exactly one fixture member: {name}")
    start = matches[0].start()
    if matches[0].group(1) == "typealias":
        return matches[0].group()
    end = re.search(r"^    }$", source[matches[0].end():], re.M)
    if end is None:
        raise ValueError(f"missing fixture member end: {name}")
    return source[start:matches[0].end() + end.end()]


def policy():
    source = (ROOT / "AtticTests/TasksFrameCostTests.swift").read_text()
    return BEGIN + source.split(BEGIN, 1)[1].split(END, 1)[0] + END + "\n"


def prepare(directory, fixture):
    if fixture == "integration":
        updated = {}
        for name, members in INTEGRATION_MEMBERS.items():
            path = directory / "AtticTests" / name
            source = path.read_text()
            current = (ROOT / "AtticTests" / name).read_text()
            for member_name in members:
                old, new = member(source, member_name), member(current, member_name)
                source = source.replace(old, new, 1)
            updated[path] = source
        for path, source in updated.items():
            path.write_text(source)
            print(f"Integration reference measurement overlay: {path}")
        return
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
    if fixture not in ("frame-row", "done", "integration"):
        raise ValueError("expected frame-row, done or integration")
    prepare(Path(directory), fixture)
