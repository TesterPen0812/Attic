#!/usr/bin/env python3
"""Summarize only complete alternating render-lab CSV pairs; Air or offline."""

import csv
import statistics as stats
import sys
from pathlib import Path


ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/render-lab")


def fmt(values):
    if not values:
        return "NA"
    return f"{stats.median(values):.1f} [{min(values):.1f}, {max(values):.1f}]"


def read(path):
    if not path.is_file():
        return None
    with path.open(newline="") as stream:
        data = list(csv.DictReader(stream))
    # A row selection can dismiss its floating panel; that experiment is
    # deliberately one cold click per launch, without a fabricated repeat.
    kinds = {row["kind"] for row in data}
    if (len(data) == 2 and kinds != {"cold", "repeat"}) or \
       (len(data) == 1 and kinds != {"cold"}) or len(data) not in (1, 2):
        return None
    try:
        result = {}
        for row in data:
            numbers = {field: float(row[field]) for field in
                       ("first_display_ms", "first_callback_ms", "capture_bias_ms",
                        "frame_gap_p90_ms", "frame_gap_max_ms")}
            for field in ("top_row_ms", "bottom_row_ms", "any_4_ms", "any_8_ms", "top_settled_ms", "bottom_settled_ms"):
                if row.get(field) and row[field] != "NA":
                    numbers[field] = float(row[field])
            result[row["kind"]] = numbers
        return result
    except (ValueError, KeyError):
        return None


for folder in sorted(ROOT.iterdir()):
    if not folder.is_dir():
        continue
    pairs = []
    numbered = sorted({int(p.name.split("-")[0]) for p in folder.glob("*-*.csv")
                       if p.name.split("-")[0].isdigit()})
    for i in numbered:
        if i % 2 != 1:
            continue
        baseline = read(folder / f"{i}-base.csv") or read(folder / f"{i + 1}-base.csv")
        flagged = read(folder / f"{i}-off.csv") or read(folder / f"{i + 1}-off.csv")
        if baseline is not None and flagged is not None:
            pairs.append((baseline, flagged))
    if not pairs:
        print(f"{folder.name}: NO COMPLETE PAIRS")
        continue
    print(f"{folder.name}: {len(pairs)} valid A/B pairs")
    for kind in ("cold", "repeat"):
        matched_pairs = [p for p in pairs if kind in p[0] and kind in p[1]]
        if not matched_pairs:
            print(f"  {kind}: not measured")
            continue
        base = [p[0][kind]["first_display_ms"] for p in matched_pairs]
        off = [p[1][kind]["first_display_ms"] for p in matched_pairs]
        delta = [x - y for x, y in zip(base, off)]
        bias = [p[c][kind]["capture_bias_ms"] for p in matched_pairs for c in (0, 1)]
        gap = [p[c][kind]["frame_gap_p90_ms"] for p in matched_pairs for c in (0, 1)]
        print(f"  {kind}: base {fmt(base)} ms; off {fmt(off)} ms; "
              f"paired base-minus-off {fmt(delta)} ms; "
              f"capture bias {fmt(bias)} ms; frame-update p90 {fmt(gap)} ms")
        for metric in ("top_row_ms", "bottom_row_ms", "any_4_ms", "any_8_ms", "top_settled_ms", "bottom_settled_ms"):
            matched = [(a[kind][metric], b[kind][metric]) for a, b in matched_pairs
                       if metric in a[kind] and metric in b[kind]]
            if matched:
                before, after = zip(*matched)
                diff = [a - b for a, b in matched]
                print(f"    {metric}: n={len(matched)} base {fmt(before)}, "
                      f"off {fmt(after)}, paired improvement {fmt(diff)} ms")
