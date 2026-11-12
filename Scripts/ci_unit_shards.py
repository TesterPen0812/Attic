#!/usr/bin/env python3
"""Select complete XCTestCase suites for the required parallel unit runner.

Unknown suites remain on the main unit runner. The emitted skip/only flags are
derived from the same set, so a suite cannot disappear between the two jobs.
"""
from pathlib import Path
import re
import sys


CLASS = re.compile(r'^\s*(?:final\s+)?class\s+([A-Za-z_]\w*)\s*:\s*XCTestCase\b', re.MULTILINE)
# The optimized costs job owns these suites; preserve that existing route.
OPTIMIZED_COST_SUITES = {'DoneSearchCostTests', 'TasksFrameCostTests', 'TasksRowBuildCostTests'}


def continuation_suites(root: Path):
    suites = set()
    for source in (root / 'AtticTests').glob('*.swift'):
        suites.update(CLASS.findall(source.read_text()))
    if 'O14FirstMouseTests' not in suites:
        raise ValueError('Missing exhaustive first-mouse suite; check XCTest discovery')
    # 11 Nov CI: A–O ~24 min, P–Z ~30 min. The exhaustive 6-pt first-mouse
    # grid takes another ~3 min, so place it with the continuation suites.
    return sorted(suite for suite in suites if suite not in OPTIMIZED_COST_SUITES
                  and (suite[0].upper() >= 'P' or suite == 'O14FirstMouseTests'))


if __name__ == '__main__':
    if len(sys.argv) != 2 or sys.argv[1] not in {'--unit-skips', '--continuation-only'}:
        raise SystemExit('usage: ci_unit_shards.py --unit-skips | --continuation-only')
    prefix = '-skip-testing:' if sys.argv[1] == '--unit-skips' else '-only-testing:'
    for suite in continuation_suites(Path(__file__).resolve().parent.parent):
        print(f'{prefix}AtticTests/{suite}')
