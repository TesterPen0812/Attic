#!/usr/bin/env python3
"""Compare every Done query's median with same-job reference samples.

The spec's candidate 16 ms median budgets remain in DoneSearchCostTests.
Individual spikes no longer gate: median <= reference median +
max(reference range, measured resolution) + 0.2 ms (OD-9).
Keep the historical reference's measurement boundaries.
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

from cost_resolution import compare, fixture_quantum

MEMORY = re.compile(r"ATTIC_DONE_SEARCH session=(\d+) query=(.*?) page/group/count_ms=.* total_ms=([\d.]+)")
PHASE5 = re.compile(r"ATTIC_PHASE5_DONE (?:session=(\d+) )?query=(.*?) legacy_page_count_lower_bound_ms=.* indexed_page_group_count_ms=([\d.]+)")


def samples(text, pattern, session_offset=0):
    """{query: {session: ms}} from one log."""
    found = defaultdict(dict)
    for line in text.splitlines():
        match = pattern.search(line)
        if match:
            session = int(match[1] or 0) + session_offset
            found[match[2]][session] = float(match[3])
    return found


def merge(parts):
    merged = defaultdict(dict)
    for part in parts:
        for query, sessions in part.items():
            merged[query].update(sessions)
    return merged


def main(directory):
    candidate_text = (directory / "done-search.log").read_text()
    baselines = [(directory / f"done-search-baseline-{i}.log").read_text() for i in (1, 2, 3)]
    fixtures = {
        "memory": (samples(candidate_text, MEMORY), samples(baselines[0], MEMORY)),
        "phase5": (samples(candidate_text, PHASE5),
                   merge(samples(text, PHASE5, session_offset=i) for i, text in enumerate(baselines))),
    }
    report = {}
    for name, (after, before) in fixtures.items():
        if not after or not before:
            print(f"{name}: no samples (candidate {len(after)} queries, baseline {len(before)})")
            return 1
        sessions = {len(values) for values in list(after.values()) + list(before.values())}
        if sessions != {3}:
            print(f"{name}: expected three sessions a query on each side, found {sorted(sessions)}")
            return 1
        if set(before) != set(after):
            raise ValueError(f"{name}: reference and candidate queries differ")
        queries = {}
        for query in sorted(before):
            reference = list(before[query].values())
            candidate = list(after[query].values())
            comparison = compare(reference, candidate,
                                 fixture_quantum(baselines + [candidate_text], f"{name}:{query}"))
            comparison['baseline_ms'] = comparison.pop('before_ms')
            comparison['candidate_ms'] = comparison.pop('after_ms')
            queries[query] = comparison
        report[name] = dict(queries=queries, passed=all(row["passed"] for row in queries.values()))
    (directory / "done-search-comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if all(row["passed"] for row in report.values()) else 1


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
