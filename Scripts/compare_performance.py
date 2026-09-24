#!/usr/bin/env python3
"""Fail only when repeated same-run measurements clearly exceed the reference.

The comparison uses measured spread rather than an invented memory/CPU target.
Both JSON files must be recorded on the same machine and OS with the same seed.
"""

import argparse
import json
from pathlib import Path
import statistics


PHASES = ("hidden_idle", "tasks_open", "canvas_open", "after_hide")
MEASURES = (
    ("physical_footprint_bytes_end", "footprint"),
    ("cpu_percent_one_core", "CPU"),
    ("package_idle_wakeups_per_s", "idle wake-ups"),
)


def series(document, phase, key):
    result = []
    for run in document["runs"]:
        matching = [item[key] for item in run["phases"] if item["phase"] == phase]
        if len(matching) != 1:
            raise ValueError(f"Missing or duplicate {phase} in run {run['run']}")
        result.append(matching[0])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    base = json.loads(args.reference.read_text())
    current = json.loads(args.candidate.read_text())
    for key in ("schema", "machine", "os", "xcode", "seed_version", "seed_counts",
                "done_history", "window_s"):
        if base[key] != current[key]:
            parser.error(f"Incomparable {key}: {base[key]!r} versus {current[key]!r}")
    if len(base["runs"]) < 3 or len(current["runs"]) < 3:
        parser.error("At least three runs are required on both sides")
    failures = []
    for phase in PHASES:
        for key, title in MEASURES:
            old = series(base, phase, key)
            new = series(current, phase, key)
            old_spread = max(old) - min(old)
            new_spread = max(new) - min(new)
            # Every candidate run must sit beyond the old range plus the
            # larger observed spread. This deliberately ignores ambiguous
            # movements on noisy hosted hardware.
            clear = min(new) > max(old) + max(old_spread, new_spread)
            print(f"{phase} {title}: reference median {statistics.median(old):.4g} "
                  f"[{min(old):.4g}, {max(old):.4g}], candidate median "
                  f"{statistics.median(new):.4g} [{min(new):.4g}, {max(new):.4g}]"
                  + (" CLEAR REGRESSION" if clear else ""))
            if clear:
                failures.append(f"{phase} {title}")
    if failures:
        raise SystemExit("Clear regressions: " + ", ".join(failures))


if __name__ == "__main__":
    main()
