#!/usr/bin/env python3
"""Extract B-11 key/phase timings from window-driver and static signpost logs."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import statistics


def intervals(path):
    pending, result = {}, []
    for line in path.read_text().splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("eventType") != "signpostEvent":
            continue
        name = event["signpostName"]
        stamp = datetime.strptime(event["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
        key = (name, event["signpostID"])
        if event["signpostType"] == "begin":
            pending[key] = stamp
        elif event["signpostType"] == "end" and key in pending:
            start = pending.pop(key)
            result.append((name, start, stamp, (stamp - start) * 1000))
    return result


def extract(prefix, run):
    keys = [(int(index), float(start), int(wrap)) for index, start, wrap in re.findall(
        r"KEY index=(\d+) start=([\d.]+) wrap=([01])", prefix.with_suffix(".drive").read_text())]
    if [k[0] for k in keys] != list(range(1, 101)):
        raise ValueError(f"Incomplete 100-key fixture: {prefix}")
    observations = re.findall(r"^OBSERVATION ([a-z-]+)$", prefix.with_suffix(".drive").read_text(), re.MULTILINE)
    if len(observations) != 1:
        raise ValueError(f"Missing observation protocol: {prefix}")
    windows = re.findall(r"WINDOW id=\d+ layer=3 width=([\d.]+) height=([\d.]+)", prefix.with_suffix(".drive").read_text())
    if len(windows) != 1:
        raise ValueError(f"Expected one measured preview panel: {prefix}")
    window = {"width": float(windows[0][0]), "height": float(windows[0][1])}
    phases = intervals(prefix.with_suffix(".signposts.jsonl"))
    wraps, ordinary, layout, ordinary_layout = [], [], [], []
    wrap_phases = {}
    for position, (index, start, wrapped) in enumerate(keys):
        stop = keys[position + 1][1] if position + 1 < len(keys) else float("inf")
        matched = {}
        for name in ("NoteKeystrokeToDraw", "NoteKeystrokeToLayout"):
            candidates = [p for p in phases if p[0] == name and start <= p[1] < stop]
            if len(candidates) != 1:
                raise ValueError(f"Expected one {name} for key {index}, got {len(candidates)}: {prefix}")
            matched[name] = candidates[0][3]
        (wraps if wrapped else ordinary).append(matched["NoteKeystrokeToDraw"])
        (layout if wrapped else ordinary_layout).append(matched["NoteKeystrokeToLayout"])
        if wrapped:
            for name, begin, end, duration in phases:
                if start <= begin < stop and name not in matched:
                    wrap_phases.setdefault(name, []).append(duration)
    if not wraps:
        raise ValueError(f"No observed caret line wraps: {prefix}")
    return {"run": run, "window": window, "observation": observations[0], "wrap_to_draw_ms": wraps, "wrap_to_layout_ms": layout,
            "ordinary_to_draw_median_ms": statistics.median(ordinary),
            "ordinary_to_layout_median_ms": statistics.median(ordinary_layout),
            "wrap_phases_ms": wrap_phases,
            "wrap_key_indices": [k[0] for k in keys if k[2]]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix", help="e.g. /tmp/attic-sweep-baseline; numbered runs append -1")
    parser.add_argument("--runs", type=int, default=6)
    parser.add_argument("--fixture", default="ordinary-note-420x460-100x-110ms")
    parser.add_argument("--pattern", default="x")
    parser.add_argument("--seed", default="default")
    parser.add_argument("--machine", required=True)
    parser.add_argument("--os", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    runs = [extract(Path(f"{args.prefix}-{run}"), run) for run in range(1, args.runs + 1)]
    if any(run["window"] != runs[0]["window"] or run["observation"] != runs[0]["observation"] for run in runs):
        raise ValueError("Panel geometry or observation protocol changed between runs")
    result = {"schema": 1, "window": runs[0]["window"], "observation": runs[0]["observation"], "machine": args.machine, "os": args.os,
              "fixture": args.fixture, "typing_pattern": args.pattern, "launch_seed": args.seed, "optimized": True,
              "executable_sha256": args.sha256,
              "runs": runs}
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Validated {len(result['runs'])} runs")


if __name__ == "__main__":
    main()
