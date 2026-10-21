#!/usr/bin/env python3
"""OD-6 for d77ec80's four Notes save timing assertions; preserve correctness."""
from pathlib import Path
import sys

REPLACEMENTS = (
    'XCTAssertLessThanOrEqual(sample.save, saveMedianLimit',
    'XCTAssertLessThanOrEqual(sample.prepared, preparedMedianLimit',
    'XCTAssertLessThanOrEqual(populated.prepared - empty.prepared, 8.652083 - 5.980709',
    'XCTAssertLessThanOrEqual(populated.save - empty.save, 55.323833 - 45.781292',
)

def prepare(root):
    path = root / 'AtticTests/NotesPageControllerTests.swift'
    source = path.read_text()
    for assertion in REPLACEMENTS:
        if source.count(assertion) != 1:
            raise ValueError(f'Expected exactly one pinned PF reference assertion: {assertion}')
        source = source.replace(assertion, assertion.replace('XCTAssert', 'CostBudget.assert'))
    path.write_text(source)

if __name__ == '__main__': prepare(Path(sys.argv[1]))
