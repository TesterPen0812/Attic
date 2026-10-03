#!/usr/bin/env python3
"""Hold the slowest Done search query sample to no regression.

The spec's 16 ms query budget applies to each query's median across three
fresh sessions (owner, 2026-10-03); DoneSearchCostTests asserts it. A single
sample is no longer held to a fixed 16 ms cap: on a shared CI runner one
sample of 24 measured 16.19 ms in a session whose median was 12.6 ms.

Instead, for each fixture (the in-memory 5,000-task seed and the disk-backed
Phase 5 seed), the candidate's slowest sample must be at most the accepted
baseline's slowest sample plus the baseline's spread, as the other cost
comparisons do with three samples: each session's slowest sample is one
sample, and the spread is the range of the baseline's three. Both sides
have three sessions:

- candidate: `done-search.log` (DoneSearchCostTests, three sessions each);
- baseline: `done-search-baseline-1.log` .. `-3.log`, the accepted build's
  query tests run three times. Its in-memory fixture measures three
  sessions in one run, so only the first run's are used; its Phase 5
  fixture measures one session a run, so each run gives one.
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

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
    candidate = (directory / "done-search.log").read_text()
    baselines = [(directory / f"done-search-baseline-{i}.log").read_text() for i in (1, 2, 3)]
    fixtures = {
        "memory": (samples(candidate, MEMORY), samples(baselines[0], MEMORY)),
        "phase5": (samples(candidate, PHASE5),
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
        def session_slowest(side):
            by_session = defaultdict(list)
            for values in side.values():
                for session, ms in values.items():
                    by_session[session].append(ms)
            return [max(by_session[s]) for s in sorted(by_session)]
        before_slowest = session_slowest(before)
        after_slowest = session_slowest(after)
        spread = max(before_slowest) - min(before_slowest)
        bound = max(before_slowest) + spread
        slowest = max(after_slowest)
        report[name] = dict(
            baseline_session_slowest_ms=before_slowest, baseline_spread_ms=spread, bound_ms=bound,
            candidate_session_slowest_ms=after_slowest, candidate_slowest_ms=slowest, passed=slowest <= bound,
            candidate_ms={query: [values[s] for s in sorted(values)] for query, values in after.items()},
            baseline_ms={query: [values[s] for s in sorted(values)] for query, values in before.items()},
        )
    (directory / "done-search-comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if all(row["passed"] for row in report.values()) else 1


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
