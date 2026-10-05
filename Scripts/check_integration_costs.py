#!/usr/bin/env python3
"""OD-8/OD-9: same-job median + max(reference range, resolution) + 0.2 ms.

Reference app: pinned A10 integration, before these test-only repairs. Both
hosts use identical current measurement fixtures. Existing Phase 1 comparisons
and the candidate's spec-mandated 16 ms median budgets remain independent.
`--done-only DIR` applies the same rendered comparison to Phase 3 logs.
"""
import ast
import json
import re
import sys
from pathlib import Path

from cost_resolution import compare, fixture_quantum, raw_samples

METRICS = {"family-summary", "status-toggle", "first-keystroke", "recovery-main-actor", "recovery-overhead", "attachment-upkeep"}
METRICS |= {f"note-{label}-{kind}" for label in
            ("5000", "empty", "populated", "empty_attachment", "populated_attachment")
            for kind in ("save", "prepared")}
METRICS |= {f"scaling-{label}-{kind}" for label in ("text", "attachment") for kind in ("save", "prepared")}
COST = re.compile(r"ATTIC_INTEGRATION_COST (\S+) median_ms=(-?[\d.]+)")
RESULT = re.compile(r"ATTIC_DONE_RESULTS run=(\d+) frame_ms=([\d.]+)")
KEY = re.compile(r"ATTIC_DONE_KEY key=(\d+) raw_ms=(\[[^\n]+?\])")


def rendered(text):
    results = {int(run): float(ms) for run, ms in RESULT.findall(text)}
    keys = {int(key): list(map(float, ast.literal_eval(raw))) for key, raw in KEY.findall(text)}
    if set(results) != {0, 1, 2} or set(keys) != set(range(len("Finished task 12"))):
        raise ValueError("incomplete Done frame/key samples")
    if any(len(values) != 3 for values in keys.values()):
        raise ValueError("expected three sessions per Done key")
    if any(ms >= 500 or ms < 0 for ms in list(results.values()) + sum(keys.values(), [])):
        raise ValueError("Done frame/key sample breached 500 ms sanity ceiling")
    return {"done-results-frame": list(results.values()),
            **{f"done-key-{key}": values for key, values in keys.items()}}


def compare_done(reference, candidate, texts=None):
    before, after = rendered(reference), rendered(candidate)
    texts = texts if texts is not None else [reference, candidate]
    return {name: compare(before[name], after[name], fixture_quantum(texts, name))
            for name in before}


def done_only(directory):
    report = compare_done((directory / "done-results-reference.log").read_text(),
                          (directory / "done-results-candidate.log").read_text())
    (directory / "done-results-comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if all(row["passed"] for row in report.values()) else 1


def main(directory):
    report = {}
    sides = {}
    texts = []
    reference_texts = []
    for side in ("baseline", "candidate"):
        blocks = []
        for sample in (1, 2, 3):
            text = (directory / f"integration-{side}-{sample}.log").read_text()
            texts.append(text)
            if side == 'baseline':
                reference_texts.append(text)
            found = COST.findall(text)
            values = {name: float(ms) for name, ms in found}
            if set(values) != METRICS or len(found) != len(METRICS):
                raise ValueError(f"{side}-{sample}: expected every metric exactly once; missing {METRICS - set(values)}")
            blocks.append(values)
        sides[side] = blocks
    for name in sorted(METRICS):
        report[name] = compare([block[name] for block in sides['baseline']],
                               [block[name] for block in sides['candidate']],
                               fixture_quantum(texts, name), raw_samples(reference_texts, name) or None)
    reference = (directory / "integration-baseline-1.log").read_text()
    done = (directory / "done-search.log").read_text()
    texts.append(done)
    report.update(compare_done(reference, done, texts))
    (directory / "integration-cost-comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if all(row["passed"] for row in report.values()) else 1


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--done-only":
        sys.exit(done_only(Path(sys.argv[2])))
    sys.exit(main(Path(sys.argv[1])))
