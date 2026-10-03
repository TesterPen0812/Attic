#!/usr/bin/env python3
"""Block frame/row regressions beyond the spread of three interleaved runs.

The 16 ms input/query budget lives in DoneSearchCostTests. This comparison
uses the existing observational frame/row probes and derives its tolerance
from their measured within-build range, plus 0.2 ms for printed rounding.
"""
import json
import re
import statistics
import sys
from pathlib import Path


def metrics(path):
    text = path.read_text()
    frame = next(line for line in text.splitlines() if line.startswith("ATTIC_FRAME_COST "))
    row = next(line for line in text.splitlines() if line.startswith("ATTIC_ROW_BUILD "))
    result = {}
    for name in ("select-1-page", "select-3-pages", "swipe-follow-frames", "swipe-settle-frames", "keystroke", "title-keystroke"):
        result[name] = float(re.search(rf"\| {name} n=\d+ median=([\d.]+)ms", frame)[1])
    click = re.search(r"click-first now=([\d.]+)ms backlog=([\d.]+)ms done=([\d.]+)ms", frame)
    for name, value in zip(("click-now", "click-later", "click-done"), click.groups()):
        result[name] = float(value)
    empty = float(re.search(r"empty=([\d.]+)ms", row)[1])
    result["row-build"] = empty + float(re.search(r" rows=\+(-?[\d.]+)ms", row)[1])
    result["lazy-row-build"] = empty + float(re.search(r"lazy-scroll=\+(-?[\d.]+)ms", row)[1])
    return result


def main(directory):
    samples = {name: [metrics(directory / f"{name}-cost-{i}.log") for i in (1, 2, 3)]
               for name in ("baseline", "candidate")}
    report = {}
    for metric in samples["baseline"][0]:
        before = [sample[metric] for sample in samples["baseline"]]
        after = [sample[metric] for sample in samples["candidate"]]
        tolerance = max(max(before) - min(before), max(after) - min(after)) + 0.2
        passed = statistics.median(after) <= statistics.median(before) + tolerance
        report[metric] = dict(before_ms=before, after_ms=after, noise_ms=tolerance, passed=passed)
    (directory / "cost-comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if all(row["passed"] for row in report.values()) else 1


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
