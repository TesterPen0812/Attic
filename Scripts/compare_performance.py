#!/usr/bin/env python3
"""Find completely separated same-run performance series.

Both JSON files must be recorded on the same machine and OS with the same seed.
A confirmation is actionable only when the same primary measure separates again.
"""

import argparse
import json
from pathlib import Path
import statistics


PHASES = ("hidden_idle", "tasks_open", "canvas_open", "after_hide", "hidden_idle_final")
MEASURES = (("physical_footprint_bytes_end", "footprint"),
            ("cpu_percent_one_core", "CPU"),
            ("interrupt_wakeups_per_s", "interrupt wake-ups"))
TIMINGS = ("CoordinatorInitToMenuStarted", "StoreOpen", "PanelRevealToOrderedFront", "PageSwitch")
PRIMARY = {("hidden_idle", "physical_footprint_bytes_end"),
           ("hidden_idle", "cpu_percent_one_core"),
           ("hidden_idle", "interrupt_wakeups_per_s"),
           ("after_hide", "physical_footprint_bytes_end"),
           ("hidden_idle_final", "physical_footprint_bytes_end")}
PRIMARY_TIMINGS = {"PanelRevealToOrderedFront"}


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
        # The first reveal starts with a hidden panel. Later order-front
        # events occur while it is already visible and are separate work.
        result.append(samples[0] if name == "PanelRevealToOrderedFront"
                      else statistics.median(samples))
    return result


def compare(title, old, new):
    # Complete separation is a measured ordering, not a CPU or memory budget.
    # Repeating the same measure on a fresh interleaved sample checks noise.
    clear = min(new) > max(old)
    print(f"{title}: reference median {statistics.median(old):.4g} "
          f"[{min(old):.4g}, {max(old):.4g}], candidate median "
          f"{statistics.median(new):.4g} [{min(new):.4g}, {max(new):.4g}]"
          + (" COMPLETE SEPARATION" if clear else ""))
    return clear


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--regressions-json", type=Path,
                        help="write the primary measures with complete separation")
    parser.add_argument("--require-common-with", type=Path,
                        help="only fail when a primary measure also separated in this earlier report")
    args = parser.parse_args()
    base = json.loads(args.reference.read_text())
    current = json.loads(args.candidate.read_text())
    for key in ("schema", "machine", "os", "xcode", "seed_version", "seed_counts",
                "done_history", "window_s"):
        if base[key] != current[key]:
            parser.error(f"Incomparable {key}: {base[key]!r} versus {current[key]!r}")
    if len(base["runs"]) < 6 or len(current["runs"]) < 6:
        parser.error("At least six runs are required on both sides")
    failures = []
    for phase in PHASES:
        for key, title in MEASURES:
            old = series(base, phase, key)
            new = series(current, phase, key)
            if compare(f"{phase} {title}", old, new) and (phase, key) in PRIMARY:
                failures.append(f"{phase} {title}")
    for name in TIMINGS:
        if compare(f"{name} ms", timing_series(base, name), timing_series(current, name)) and name in PRIMARY_TIMINGS:
            failures.append(name)
    if args.regressions_json:
        args.regressions_json.write_text(json.dumps(failures, indent=2) + "\n")
    if args.require_common_with:
        earlier = json.loads(args.require_common_with.read_text())
        repeated = sorted(set(failures) & set(earlier))
        if repeated:
            print("::warning::Confirmed performance separation in " + ", ".join(repeated))
            raise SystemExit("Confirmed clear regressions: " + ", ".join(repeated))
        print("No primary measure repeated its separation in the confirmation run")
        return
    if failures:
        raise SystemExit("Clear regressions: " + ", ".join(failures))


if __name__ == "__main__":
    main()
