#!/usr/bin/env python3
"""Block frame/row regressions beyond the baseline's own spread.

Three interleaved samples each of the baseline and the candidate build. A
metric passes when the candidate's median is at most the baseline's median
plus max(baseline range, measured resolution), plus 0.2 ms for printed
rounding (OD-9). Only reference samples determine spread and resolution.
The 16 ms budgets live in
DoneSearchCostTests (macos-ci.yml runs both).

`search-show` is the frame in which Done search results appear: each
keystroke's frame for a baseline that searched on every key, the worse of
the slowest keystroke and the separate results frame for one that waits
for the typing to pause.
"""
import json
import re
import sys
from pathlib import Path

from cost_resolution import compare, fixture_quantum


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
    # The frame that shows Done search results. The baseline published
    # and rebuilt on every keystroke (its keystroke median); the candidate
    # publishes after 75 ms idle, so it is the worse of its slowest
    # keystroke frame and the separate results frame.
    keys = re.search(r"\| search-keystroke n=\d+ median=([\d.]+)ms .*?max=([\d.]+)ms", frame)
    shown = re.search(r"\| search-results ([\d.]+)ms", frame)
    result["search-show"] = max(float(keys[2]), float(shown[1])) if shown else float(keys[1])
    empty = float(re.search(r"empty=([\d.]+)ms", row)[1])
    result["row-build"] = empty + float(re.search(r" rows=\+(-?[\d.]+)ms", row)[1])
    result["lazy-row-build"] = empty + float(re.search(r"lazy-scroll=\+(-?[\d.]+)ms", row)[1])
    return result


def main(directory):
    texts = [(directory / f"{name}-cost-{i}.log").read_text()
             for name in ("baseline", "candidate") for i in (1, 2, 3)]
    samples = {name: [metrics(directory / f"{name}-cost-{i}.log") for i in (1, 2, 3)]
               for name in ("baseline", "candidate")}
    report = {}
    for metric in samples["baseline"][0]:
        before = [sample[metric] for sample in samples["baseline"]]
        after = [sample[metric] for sample in samples["candidate"]]
        report[metric] = compare(before, after, fixture_quantum(texts, metric))
    (directory / "cost-comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if all(row["passed"] for row in report.values()) else 1


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
