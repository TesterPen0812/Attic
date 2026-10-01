#!/usr/bin/env python3
"""Reads the on-screen performance gate's runs (`Scripts/perf_onscreen.zsh`)
and prints a comparison table: per run, then per build (the mean of its valid
runs, with the run-to-run spread), and the candidate against the baseline.

Each run `<dir>/<label>-<n>` has:
  .frames  the app's frame monitor (ATTIC_FRAME <media s> <gap ms>, ATTIC_EVENT …)
  .drive   the driver's marks (MARK <name> <media s> <wall s>), then
           ws= app= drive_exit= (the driver's exit status, written by the gate)
  .top     `top -l` samples of the app's and WindowServer's CPU (`-pid` each)
  .gpu     GPU <wall s> "Device Utilization %"=N "Renderer Utilization %"=N …

A run is valid only if the driver exited 0 and printed DONE, both phases
(scroll and swipe) have their start and end marks and frames, GPU samples
were recorded, and the app echoed input (scrolls or page settles). An invalid
run is listed with its reasons as a diagnostic and kept out of every mean and
delta. The comparison is COMPLETE only with `--rounds` rounds in which both
builds' runs are valid (the means use exactly those rounds, so both builds
average the same interleaved rounds); anything less is INCOMPLETE, no
comparison is printed, and the exit status is 1. A CPU sample the table lacks
is a missing value (—), never 0, and does not invalidate a run.

Missed frames: a gap longer than 1.5 refreshes counts its whole refreshes
beyond the first. It sets no budget of its own: compare against the baseline
and read the spread (no invented targets).
"""
import argparse
import re
import statistics as st
import sys
from datetime import datetime
from pathlib import Path

PHASES = ("scroll", "swipe")


def lines(path):
    with open(path, errors="replace") as handle:
        return handle.read().splitlines(keepends=True)


def load_frames(path):
    frames, events, refresh = [], [], 120
    if not Path(path).exists():
        return frames, events, refresh
    for line in lines(path):
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
    """The driver's marks, the two pids, its exit status (None if the gate
    never wrote one: it was interrupted) and a status line: DONE, or the
    first ABORT/NO_/REFUSED line, or "no DONE"."""
    marks, ws, app, exit_code, status = {}, None, None, None, "no DONE"
    if not Path(path).exists():
        return marks, ws, app, exit_code, "no driver output"
    done = False
    for line in lines(path):
        parts = line.split()
        if line.startswith("MARK") and len(parts) >= 3:
            marks[parts[1]] = (float(parts[2]), float(parts[3]) if len(parts) > 3 else None)
        elif line.startswith("ws="):
            fields = dict(item.split("=", 1) for item in parts if "=" in item)
            ws, app = fields.get("ws"), fields.get("app")
            if fields.get("drive_exit", "").lstrip("-").isdigit():
                exit_code = int(fields["drive_exit"])
        elif line.startswith("DONE"):
            done = True
        elif line.startswith(("ABORT", "NO_", "REFUSED")) and status == "no DONE":
            status = line.strip()
    return marks, ws, app, exit_code, "DONE" if done else status


def load_top(path, ws, app, start, end):
    """The app's and WindowServer's CPU % over [start, end] (wall clock), each
    as the list of its own samples. A sample that does not list a pid
    contributes nothing to that pid's list (a missing value, never 0). top's
    first sample is a lifetime average: skipped."""
    samples, current, stamp = [], None, None
    for line in lines(path):
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
    return [s[app] for s in samples if app in s], [s[ws] for s in samples if ws in s]


def load_gpu(path, start, end):
    device, renderer = [], []
    for line in lines(path):
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
    marks, ws, app, exit_code, status = load_drive(f"{base}.drive")
    budget = 1000 / refresh
    result = {"label": Path(base).name, "status": status, "refresh": refresh, "drive_exit": exit_code}
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
        if w:
            result["ws_cpu"] = (st.mean(w), max(w))
    result["gpu_samples"] = 0
    if Path(f"{base}.gpu").exists():
        device, renderer = load_gpu(f"{base}.gpu", start, end)
        result["gpu_samples"] = len(device)
        if device:
            result["gpu"] = (st.mean(device), max(device))
        if renderer:
            result["renderer"] = (st.mean(renderer), max(renderer))
    result["problems"] = problems(result, marks)
    result["valid"] = not result["problems"]
    return result


def problems(r, marks):
    """Why a run does not count (empty: it counts)."""
    found = []
    if r["drive_exit"] is None:
        found.append("the driver left no exit status (interrupted)")
    elif r["drive_exit"] != 0:
        found.append(f"the driver exited {r['drive_exit']}")
    if r["status"] != "DONE":
        found.append(r["status"])
    for name in (f"{p}_{edge}" for p in PHASES for edge in ("start", "end")):
        if name not in marks:
            found.append(f"no {name} mark")
    for phase in PHASES:
        if f"{phase}_start" in marks and f"{phase}_end" in marks and not r.get(phase):
            found.append(f"no frames in the {phase} phase")
    if r["gpu_samples"] == 0:
        found.append("no GPU samples")
    if r["scroll_gestures_seen"] == 0 and r["page_choices_seen"] == 0:
        found.append("no input reached the app")
    return found


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


def load_runs(directory):
    """{build: {round: analysed run}} for every run in the directory."""
    labels = {Path(f).stem for pattern in ("*.frames", "*.drive") for f in Path(directory).glob(pattern)}
    runs = {}
    for label in sorted(labels):
        build, _, number = label.rpartition("-")
        if not build or not number.isdigit():
            continue
        runs.setdefault(build, {})[int(number)] = analyse(str(Path(directory) / label))
    return runs


def paired_rounds(runs, baseline, candidate):
    """The rounds in which both builds' runs are valid."""
    numbers = sorted(set(runs.get(baseline, {})) | set(runs.get(candidate, {})))
    return [n for n in numbers
            if runs.get(baseline, {}).get(n, {}).get("valid") and runs.get(candidate, {}).get(n, {}).get("valid")]


def main(directory, baseline, candidate, rounds=2):
    """Prints the report; returns the exit status: 0 for a complete
    comparison, 1 for an INCOMPLETE one."""
    runs = load_runs(directory)
    paired = paired_rounds(runs, baseline, candidate)
    complete = len(paired) >= rounds
    names = [n for n, _ in metrics({})]
    print(f"\nPer run ({directory}; invalid runs are diagnostics only)")
    print("| run | " + " | ".join(names) + " | input seen | status |")
    print("|---" * (len(names) + 3) + "|")
    for build in (baseline, candidate):
        for _, r in sorted(runs.get(build, {}).items()):
            seen = f"{r['scroll_gestures_seen']} scrolls, {r['page_choices_seen']} settles"
            status = "valid" if r["valid"] else "INVALID: " + "; ".join(r["problems"])
            print(f"| {r['label']} | " + " | ".join(fmt(v) for _, v in metrics(r)) + f" | {seen} | {status} |")
    if complete:
        print(f"\nComparison: COMPLETE, {len(paired)} paired valid rounds ({', '.join(map(str, paired))})")
        print("\nPer build: mean of its valid paired runs (spread: max − min between its runs)")
        print("| build | " + " | ".join(names) + " |")
        print("|---" * (len(names) + 1) + "|")
        means = {}
        for build in (baseline, candidate):
            rs = [runs[build][n] for n in paired]
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
        print("\nCandidate − baseline (positive is worse; compare with the spread above)")
        print("| " + " | ".join(names) + " |")
        print("|---" * len(names) + "|")
        deltas = []
        for b, c in zip(means[baseline], means[candidate]):
            deltas.append("—" if b is None or c is None else f"{c - b:+.1f}")
        print("| " + " | ".join(deltas) + " |")
        return 0
    have = {build: sum(1 for r in runs.get(build, {}).values() if r["valid"]) for build in (baseline, candidate)}
    print(f"\nComparison: INCOMPLETE. It needs {rounds} rounds in which both builds' runs are valid; "
          f"there are {len(paired)} (valid runs: {baseline} {have[baseline]}, {candidate} {have[candidate]}). "
          "No means or deltas are printed: do not read the per-run rows as a result.")
    return 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    parser.add_argument("--rounds", type=int, default=2)
    arguments = parser.parse_args()
    sys.exit(main(arguments.directory, arguments.baseline, arguments.candidate, arguments.rounds))
