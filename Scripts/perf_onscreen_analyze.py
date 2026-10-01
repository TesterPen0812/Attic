#!/usr/bin/env python3
"""Reads the on-screen performance gate's runs (`Scripts/perf_onscreen.zsh`)
and prints a comparison table: per run, then per build (the mean of its runs,
with the run-to-run spread), and the candidate against the baseline.

Each run `<dir>/<label>-<n>` has:
  .frames  the app's frame monitor (ATTIC_FRAME <media s> <gap ms>, ATTIC_EVENT …)
  .drive   the driver's marks (MARK <name> <media s> <wall s>), ws= app=
  .top     `top -l` samples (app and WindowServer CPU)
  .gpu     GPU <wall s> "Device Utilization %"=N "Renderer Utilization %"=N …

Missed frames: a gap longer than 1.5 refreshes counts its whole refreshes
beyond the first. It sets no budget of its own: compare against the baseline
and read the spread (no invented targets).
"""
import re
import statistics as st
import sys
from datetime import datetime
from pathlib import Path

PHASES = ("scroll", "swipe")


def load_frames(path):
    frames, events, refresh = [], [], 120
    for line in open(path, errors="replace"):
        if line.startswith("ATTIC_FRAME_START"):
            m = re.search(r"refresh=(\d+)", line)
            refresh = int(m.group(1)) if m else 120
        elif line.startswith("ATTIC_FRAME "):
            parts = line.split()
            if len(parts) >= 3:
                frames.append((float(parts[1]), float(parts[2])))
        elif line.startswith("ATTIC_EVENT "):
            parts = line.split(maxsplit=2)
            if len(parts) >= 3:
                events.append((float(parts[1]), parts[2].strip()))
    return frames, events, refresh


def load_drive(path):
    marks, ws, app, status = {}, None, None, "ok"
    for line in open(path, errors="replace"):
        parts = line.split()
        if line.startswith("MARK") and len(parts) >= 3:
            marks[parts[1]] = (float(parts[2]), float(parts[3]) if len(parts) > 3 else None)
        elif line.startswith("ws="):
            fields = dict(item.split("=", 1) for item in parts if "=" in item)
            ws, app = fields.get("ws"), fields.get("app")
        elif line.startswith(("ABORT", "NO_", "REFUSED")):
            status = line.strip()
    return marks, ws, app, status


def load_top(path, ws, app, start, end):
    """Mean and peak CPU % of the app and WindowServer over [start, end]
    (wall clock). top's first sample is a lifetime average: skipped."""
    samples, current, stamp = [], None, None
    for line in open(path, errors="replace"):
        m = re.match(r"(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})", line)
        if m:
            stamp = datetime.strptime(m.group(1), "%Y/%m/%d %H:%M:%S").timestamp()
            continue
        if line.startswith("Processes:"):
            current = {"time": stamp}
            samples.append(current)
            continue
        parts = line.split()
        if current is not None and len(parts) >= 3 and parts[0].isdigit():
            try:
                current[parts[0]] = float(parts[-1])
            except ValueError:
                pass
    samples = samples[1:]
    if start is not None and end is not None:
        timed = [s for s in samples if s.get("time") is None or start - 1 <= s["time"] <= end + 1]
        samples = timed or samples
    a = [s.get(app, 0.0) for s in samples]
    w = [s.get(ws, 0.0) for s in samples]
    return a, w


def load_gpu(path, start, end):
    device, renderer = [], []
    for line in open(path, errors="replace"):
        parts = line.split()
        if len(parts) < 2 or parts[0] != "GPU":
            continue
        t = float(parts[1])
        if start is not None and end is not None and not (start <= t <= end):
            continue
        d = re.search(r'"Device Utilization %"=(\d+)', line)
        r = re.search(r'"Renderer Utilization %"=(\d+)', line)
        if d:
            device.append(int(d.group(1)))
        if r:
            renderer.append(int(r.group(1)))
    return device, renderer


def frame_stats(gaps, budget, seconds):
    if not gaps:
        return None
    long_gaps = [g for g in gaps if g > budget * 1.5]
    missed = sum(max(0, round(g / budget) - 1) for g in long_gaps)
    expected = seconds * 1000 / budget
    ordered = sorted(gaps)
    return {
        "frames": len(gaps),
        "missed_pct": 100 * missed / expected if expected else 0,
        "worst": max(gaps),
        "p95": ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))],
    }


def analyse(base):
    frames, events, refresh = load_frames(f"{base}.frames")
    marks, ws, app, status = load_drive(f"{base}.drive")
    budget = 1000 / refresh
    result = {"label": Path(base).name, "status": status, "refresh": refresh}
    for phase in PHASES:
        s, e = marks.get(f"{phase}_start"), marks.get(f"{phase}_end")
        if not s or not e:
            continue
        gaps = [g for t, g in frames if s[0] <= t <= e[0]]
        result[phase] = frame_stats(gaps, budget, e[0] - s[0])
    # The picker: the frames in the second after it opened (the app's echo).
    opened = [t for t, text in events if text.startswith("picker-open")]
    if opened:
        gaps = [g for t, g in frames if opened[0] <= t <= opened[0] + 1.0]
        result["picker"] = frame_stats(gaps, budget, 1.0)
    # Did the input reach the app? (its own echoes)
    result["scroll_gestures_seen"] = sum(1 for _, text in events if text == "scroll-began")
    result["page_choices_seen"] = sum(1 for _, text in events if text.startswith("settle-end"))
    wall = [m[1] for m in marks.values() if m[1] is not None]
    start, end = (min(wall), max(wall)) if wall else (None, None)
    if Path(f"{base}.top").exists() and ws and app:
        a, w = load_top(f"{base}.top", ws, app, start, end)
        if a:
            result["app_cpu"] = (st.mean(a), max(a))
            result["ws_cpu"] = (st.mean(w), max(w))
    if Path(f"{base}.gpu").exists():
        device, renderer = load_gpu(f"{base}.gpu", start, end)
        if device:
            result["gpu"] = (st.mean(device), max(device))
        if renderer:
            result["renderer"] = (st.mean(renderer), max(renderer))
    return result


def metrics(r):
    """The table's columns, as (name, value) with None when missing."""
    def get(phase, key):
        return r.get(phase, {}).get(key) if r.get(phase) else None
    worst = max([v for v in (get("scroll", "worst"), get("swipe", "worst")) if v is not None], default=None)
    p95 = max([v for v in (get("scroll", "p95"), get("swipe", "p95")) if v is not None], default=None)
    return [
        ("missed scroll %", get("scroll", "missed_pct")),
        ("missed swipe %", get("swipe", "missed_pct")),
        ("worst ms", worst),
        ("p95 ms", p95),
        ("picker worst ms", get("picker", "worst")),
        ("app CPU %", r.get("app_cpu", (None,))[0]),
        ("WindowServer CPU %", r.get("ws_cpu", (None,))[0]),
        ("GPU mean %", r.get("gpu", (None,))[0]),
        ("GPU peak %", r.get("gpu", (None, None))[1]),
    ]


def fmt(v):
    return "—" if v is None else f"{v:.1f}"


def main(directory, baseline, candidate):
    runs = {}
    for frames in sorted(Path(directory).glob("*.frames")):
        base = str(frames)[: -len(".frames")]
        label = Path(base).name
        build = label.rsplit("-", 1)[0]
        runs.setdefault(build, []).append(analyse(base))
    names = [n for n, _ in metrics({})]
    print(f"\nPer run ({directory})")
    print("| run | " + " | ".join(names) + " | input seen | status |")
    print("|---" * (len(names) + 3) + "|")
    for build in (baseline, candidate):
        for r in runs.get(build, []):
            seen = f"{r['scroll_gestures_seen']} scrolls, {r['page_choices_seen']} settles"
            print(f"| {r['label']} | " + " | ".join(fmt(v) for _, v in metrics(r)) + f" | {seen} | {r['status']} |")
    print("\nPer build: mean of its runs (spread: max − min between its runs)")
    print("| build | " + " | ".join(names) + " |")
    print("|---" * (len(names) + 1) + "|")
    means = {}
    for build in (baseline, candidate):
        rs = runs.get(build, [])
        cells, values = [], []
        for i, _ in enumerate(names):
            vals = [metrics(r)[i][1] for r in rs if metrics(r)[i][1] is not None]
            if not vals:
                cells.append("—")
                values.append(None)
                continue
            mean = st.mean(vals)
            values.append(mean)
            cells.append(f"{mean:.1f} (±{(max(vals) - min(vals)) / 2:.1f})")
        means[build] = values
        print(f"| {build} | " + " | ".join(cells) + " |")
    if baseline in means and candidate in means:
        print("\nCandidate − baseline (positive is worse; compare with the spread above)")
        print("| " + " | ".join(names) + " |")
        print("|---" * len(names) + "|")
        deltas = []
        for b, c in zip(means[baseline], means[candidate]):
            deltas.append("—" if b is None or c is None else f"{c - b:+.1f}")
        print("| " + " | ".join(deltas) + " |")
    bad = [r for rs in runs.values() for r in rs if r["status"] != "ok"]
    if bad:
        print("\nRuns that stopped early: " + ", ".join(f"{r['label']} ({r['status']})" for r in bad))
    # (A build older than the gate echoes no scrolls, only its settles.)
    blind = [r for rs in runs.values() for r in rs if r["scroll_gestures_seen"] == 0 and r["page_choices_seen"] == 0]
    if blind:
        print("\nWARNING: no input reached the app in: " + ", ".join(r["label"] for r in blind))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: perf_onscreen_analyze.py <run dir> <baseline label> <candidate label>")
    main(*sys.argv[1:])
