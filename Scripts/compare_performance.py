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
    ("interrupt_wakeups_per_s", "interrupt wake-ups"),
)
TIMINGS = ("AppLaunchToMenuReady", "StoreOpen", "PanelRevealToInteractive", "PageSwitch")


def series(document, phase, key):
    result = []
    for run in document["runs"]:
        matching = [item for item in run["phases"] if item["phase"] == phase]
        if len(matching) != 1:
            raise ValueError(f"Missing or duplicate {phase} in run {run['run']}")
        item = matching[0]
        # The pinned Phase 0 reference has the raw counter and duration;
        # compute its rate here so later probe versions remain comparable.
        value = (item["interrupt_wakeups"] / item["duration_s"]
                 if key == "interrupt_wakeups_per_s" else item[key])
        result.append(value)
    return result


def timing_series(document, name):
    result = []
    for run in document["runs"]:
        samples = [item["milliseconds"] for item in run["timings"] if item["name"] == name]
        if not samples:
            raise ValueError(f"Missing {name} timing in run {run['run']}")
        # A slow first reveal must not disappear behind later warm reveals.
        result.append(max(samples) if name == "PanelRevealToInteractive"
                      else statistics.median(samples))
    return result


def compare(title, old, new):
    old_spread = max(old) - min(old)
    # Every candidate run must sit beyond the old range plus one more
    # reference spread. A noisy candidate cannot mask a consistently higher
    # floor, while an isolated slow run remains a review item.
    clear = min(new) > max(old) + old_spread
    print(f"{title}: reference median {statistics.median(old):.4g} "
          f"[{min(old):.4g}, {max(old):.4g}], candidate median "
          f"{statistics.median(new):.4g} [{min(new):.4g}, {max(new):.4g}]"
          + (" CLEAR REGRESSION" if clear else ""))
    return clear


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
            if compare(f"{phase} {title}", old, new):
                failures.append(f"{phase} {title}")
    for name in TIMINGS:
        if compare(f"{name} ms", timing_series(base, name), timing_series(current, name)):
            failures.append(name)
    if failures:
        raise SystemExit("Clear regressions: " + ", ".join(failures))


if __name__ == "__main__":
    main()
