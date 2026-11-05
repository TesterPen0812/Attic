#!/usr/bin/env python3
"""Join own-process IdleLatency candidates to ScreenCaptureKit pixel timestamps.

Usage on Air: python3 Scripts/render_lab_marker_gap.py /tmp/render-lab /tmp/renderlab-idle.log
The OS log must be filtered to the AtticRenderLab process and IdleLatency category.
"""

import csv
import re
import statistics
import sys
from pathlib import Path


root, logfile = map(Path, sys.argv[1:3])
inputs = {}
frames = {}
for line in logfile.read_text(errors="replace").splitlines():
    m = re.search(r"AtticRenderLab\[(\d+):[^]]+\].*\binput id=(\d+).*\borigin=([\d.]+).*\bdelivery_ms=([\d.]+)", line)
    if m:
        pid, serial, origin, delivery = m.groups()
        inputs[(pid, serial)] = (float(origin), float(delivery))
    m = re.search(r"AtticRenderLab\[(\d+):[^]]+\].*\bfirst_frame_candidate id=(\d+) since_input_ms=([\d.]+)", line)
    if m:
        pid, serial, elapsed = m.groups()
        frames[(pid, serial)] = float(elapsed)


for folder in sorted(root.iterdir()):
    if not folder.is_dir() or not (folder / "sequence.log").exists():
        continue
    pids = {}
    current = None
    for line in (folder / "sequence.log").read_text(errors="replace").splitlines():
        m = re.search(r"STREAM_READY pid=(\d+)\b", line)
        if m:
            current = m.group(1)
        m = re.search(r"OUTPUT /tmp/render-lab/[^/]+/(\d+-(?:base|off)\.csv)", line)
        if m and current:
            pids[m.group(1)] = current
    samples = {}
    for csvfile in folder.glob("*-*.csv"):
        pid = pids.get(csvfile.name)
        if not pid:
            continue
        for row in csv.DictReader(csvfile.open(newline="")):
            if row["first_display_ms"] == "NA":
                continue
            down = float(row["click_down_s"])
            near = [(abs(origin - down), serial, origin, delivery) for (candidate_pid, serial), (origin, delivery) in inputs.items()
                    if candidate_pid == pid and abs(origin - down) < 0.08]
            if not near:
                continue
            _, serial, origin, delivery = min(near)
            candidate = frames.get((pid, serial))
            if candidate is None:
                continue
            timestamp = float(row["release_s"]) + float(row["first_display_ms"]) / 1000
            gap = (timestamp - (origin + candidate / 1000)) * 1000
            condition = "base" if "base" in csvfile.name else "off"
            samples.setdefault((condition, row["kind"]), []).append((candidate, gap, delivery))
    if not samples:
        continue
    print(f"{folder.name} candidates vs pixels (from same input, ms):")
    for (condition, kind), values in sorted(samples.items()):
        candidate, gaps, delivery = zip(*values)
        m = statistics.median
        print(f"  {condition} {kind} n={len(values)} input delivery {m(delivery):.1f} "
              f"app candidate {m(candidate):.1f} pixel-after-candidate {m(gaps):.1f} "
              f"[{min(gaps):.1f}, {max(gaps):.1f}]")
