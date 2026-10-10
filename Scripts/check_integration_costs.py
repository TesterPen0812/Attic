#!/usr/bin/env python3
"""OD-8/OD-9: same-job median + max(reference range, resolution) + 0.2 ms.

OD-17 differences use the sum of their components' noise allowances.

Reference app: pinned A10 integration, before these test-only repairs. Both
hosts use identical current measurement fixtures. Existing Phase 1 comparisons
and the candidate's spec-mandated 16 ms median budgets remain independent.
"""
import ast
import json
import re
import sys
from pathlib import Path

from decimal import Decimal

from cost_resolution import compare, compare_derived, fixture_quantum, raw_samples

METRICS = {"family-summary", "status-toggle", "first-keystroke", "recovery-main-actor", "recovery-overhead", "attachment-upkeep"}
METRICS |= {f"note-{label}-{kind}" for label in
            ("5000", "empty", "populated", "empty_attachment", "populated_attachment")
            for kind in ("save", "prepared")}
METRICS |= {f"scaling-{label}-{kind}" for label in ("text", "attachment") for kind in ("save", "prepared")}
DERIVED = {f"scaling-{label}-{kind}": (f"note-{full}-{kind}", f"note-{empty}-{kind}")
           for label, full, empty in (("text", "populated", "empty"),
                                      ("attachment", "populated_attachment", "empty_attachment"))
           for kind in ("save", "prepared")}
DERIVED['recovery-overhead'] = ('recovery-main-actor', 'recovery-control')
COST = re.compile(r"ATTIC_INTEGRATION_COST (\S+) median_ms=(-?[\d.]+)")
CONTROL = re.compile(r"NOTE_RECOVERY_CONTROL_MAIN_ACTOR_MS_MEDIAN=([\d.eE+-]+)")
RESULT = re.compile(r"ATTIC_DONE_RESULTS run=(\d+) frame_ms=([\d.]+)")
KEY = re.compile(r"ATTIC_DONE_KEY key=(\d+) raw_ms=(\[[^\n]+?\])")


def control_samples(texts):
    # The existing fixture prints checkpoint and paired checkpoint-control
    # samples. Recover control readings without changing measurement code.
    result = []
    for text in texts:
        checkpoint = raw_samples([text], 'recovery-main-actor')
        overhead = raw_samples([text], 'recovery-overhead')
        if len(checkpoint) != len(overhead):
            raise ValueError('incomplete paired recovery component samples')
        result.extend(float(Decimal(str(a)) - Decimal(str(b)))
                      for a, b in zip(checkpoint, overhead))
    return result


def rendered(text, reference_only=False):
    results = {int(run): float(ms) for run, ms in RESULT.findall(text)}
    keys = {int(key): list(map(float, ast.literal_eval(raw))) for key, raw in KEY.findall(text)}
    if set(results) != {0, 1, 2} or set(keys) != set(range(len("Finished task 12"))):
        raise ValueError("incomplete Done frame/key samples")
    if any(len(values) != 3 for values in keys.values()):
        raise ValueError("expected three sessions per Done key")
    if any(ms < 0 or (ms >= 500 and not reference_only)
           for ms in list(results.values()) + sum(keys.values(), [])):
        raise ValueError("Done frame/key sample breached 500 ms sanity ceiling")
    return {"done-results-frame": list(results.values()),
            **{f"done-key-{key}": values for key, values in keys.items()}}


def main(directory, include_rendered=True):
    metrics = METRICS if include_rendered else METRICS - {"first-keystroke"}
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
            if not metrics <= set(values) or set(values) - METRICS or len(found) != len(values):
                raise ValueError(f"{side}-{sample}: expected every metric exactly once; missing {metrics - set(values)}")
            control = CONTROL.findall(text)
            if len(control) != 1:
                raise ValueError(f'{side}-{sample}: expected one recovery control median')
            values['recovery-control'] = float(control[0])
            blocks.append(values)
        sides[side] = blocks
    components = {}
    for name in sorted((metrics - DERIVED.keys()) | {'recovery-control'}):
        calibration = control_samples(reference_texts) if name == 'recovery-control' else raw_samples(reference_texts, name)
        components[name] = compare([block[name] for block in sides['baseline']],
                                   [block[name] for block in sides['candidate']],
                                   fixture_quantum(texts, name), calibration or None)
        if name in metrics:
            report[name] = components[name]
    for name, parts in sorted(DERIVED.items()):
        report[name] = compare_derived([block[name] for block in sides['baseline']],
                                       [block[name] for block in sides['candidate']],
                                       {part: components[part] for part in parts})
    if include_rendered:
        if (directory / "done-rendered-pairs.json").exists():
            from sample_done_costs import readings
            before, after, paired_texts = readings(directory, rendered)
            texts.extend(paired_texts)
        else:
            if any(directory.glob("rendered-*.log")):
                raise ValueError("paired Done logs require their complete manifest")
            # Retain support for archived pre-round10 artifacts.
            before = rendered((directory / "integration-baseline-1.log").read_text(), reference_only=True)
            done = (directory / "done-search.log").read_text()
            texts.append(done)
            after = rendered(done)
        for name in before:
            report[name] = compare(before[name], after[name], fixture_quantum(texts, name))
    (directory / "integration-cost-comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if all(row["passed"] for row in report.values()) else 1


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
