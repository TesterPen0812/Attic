#!/usr/bin/env python3
"""Guard on-screen note wrap latency against a measured same-machine baseline.

Each run supplies wrap_to_draw_ms and wrap_to_layout_ms. Compare the median
of each run's worst wrap with the baseline median plus its observed run-to-run range.
There is no fixed millisecond target. Keep profiler runs out of both samples.
"""
import argparse
import json
import math
from pathlib import Path
import statistics

MEASURES = ("wrap_to_draw_ms", "wrap_to_layout_ms")


def series(document, measure):
    runs = document["runs"]
    if len(runs) < 6:
        raise ValueError("At least six unprofiled runs are required")
    result = []
    for run in runs:
        values = run[measure]
        if not values or any(not isinstance(v, (int, float)) or not math.isfinite(v) or v <= 0 for v in values):
            raise ValueError(f"Missing or invalid {measure} in run {run['run']}")
        result.append(max(values))
    return result


def compare(baseline, candidate):
    for key in ("schema", "machine", "os", "fixture", "optimized", "window", "typing_pattern", "launch_seed", "observation"):
        if baseline[key] != candidate[key]:
            raise ValueError(f"Incomparable {key}")
    failures = []
    rows = []
    for measure in MEASURES:
        before, after = series(baseline, measure), series(candidate, measure)
        center = statistics.median(before)
        tolerance = max(before) - min(before)
        actual = statistics.median(after)
        limit = center + tolerance
        rows.append({"measure": measure, "baseline_median_ms": center,
                     "baseline_spread_ms": tolerance, "limit_ms": limit,
                     "candidate_median_ms": actual})
        if actual > limit:
            failures.append(measure)
    return rows, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    try:
        rows, failures = compare(json.loads(args.baseline.read_text()), json.loads(args.candidate.read_text()))
    except (KeyError, ValueError, TypeError) as error:
        parser.error(str(error))
    for row in rows:
        print(json.dumps(row, sort_keys=True))
    if failures:
        parser.exit(1, "Wrap latency regressed: " + ", ".join(failures) + "\n")


if __name__ == "__main__":
    main()
