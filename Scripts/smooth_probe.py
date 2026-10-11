#!/usr/bin/env python3
"""Targeted Notes/Tasks probe. Invoke under /tmp/attic-screen.lock.

Only the round's phasex preview is accepted. Each launch owns a fresh disk
store. Never advances the original probe past Tasks (its next page is Canvas).
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time
import uuid

from performance_probe import park_pointer, wait_for_phase

BUNDLE = "com.taha.Attic.preview.phasex"


def check_retention(records):
    """Bounds observed in both 60-visit disk baselines (200 / 5,000 lines).

    Count engine-owned layout managers, not unrelated AppKit field editors.
    Footprint includes allocator/graphics/debugger transients and is diagnostic.
    """
    visits = [r for r in records if r["phase"].startswith("smooth_visit_")]
    if [r["phase"] for r in visits] != [f"smooth_visit_{n}" for n in range(1, 61)]:
        raise ValueError("Expected all sixty visits once and in order")
    for n, record in enumerate(visits, 1):
        if not (1 <= record["engines"] <= 8):
            raise ValueError(f"Visit {n}: warm engine retention exceeded measured baseline")
        if record["layouts"] != 1:
            raise ValueError(f"Visit {n}: expected exactly one attached editor layout")
        if record["tasks"] != n:
            raise ValueError(f"Visit {n}: task workload did not complete")


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def sample(pid):
    helper = Path(__file__).resolve().parent.parent / ".build/smooth-process-sample"
    if not helper.exists():
        run("/usr/bin/clang", str(Path(__file__).with_name("perf_process_sample.c")), "-o", str(helper))
    return json.loads(subprocess.check_output([str(helper), str(pid)], text=True))


def allocation_summary(pid, output, label):
    # No content or environment dumps. Heap/class counts and VM categories only.
    for name, args in (
        ("heap", ["/usr/bin/heap", "--noContent", "-s", str(pid)]),
        ("vmmap", ["/usr/bin/vmmap", "-summary", str(pid)]),
        ("leaks", ["/usr/bin/leaks", "--noContent", "--nostacks", str(pid)]),
    ):
        with (output / f"{label}-{name}.txt").open("w") as log:
            result = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, text=True)
        print(f"{label} {name} exit={result.returncode}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["reveal", "soak"], default="reveal")
    parser.add_argument("--allocations", action="store_true")
    parser.add_argument("--long", action="store_true")
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != BUNDLE:
        raise RuntimeError("Only the authorized phasex preview is accepted")
    existing = subprocess.check_output(["/usr/bin/osascript", "-e", f'application id "{BUNDLE}" is running'], text=True).strip()
    if existing == "true":
        raise RuntimeError("A phasex preview is already running; leaving it untouched")
    args.output.mkdir(parents=True, exist_ok=True)
    base = Path.home() / f"Library/Containers/{BUNDLE}/Data/Library/Application Support/AtticPerformanceStores"
    base.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="attic-perf-smooth-", dir=base))
    token = str(uuid.uuid4())
    (root / ".attic-perf-owner").write_text(token)
    env = {
        "ATTIC_UI_TESTING": "1", "ATTIC_UI_TEST_DISPLAY": "external",
        "ATTIC_UI_TEST_CANVAS_PERSISTENCE": "1", "ATTIC_PERF_STORE_ROOT": str(root),
        "ATTIC_PERF_OWNER_TOKEN": token, "ATTIC_PERF_PROBE": "1",
        "ATTIC_PERF_EXTERNAL_CONTROL": "1", "ATTIC_PERF_CORNER": "bottomLeft",
        "ATTIC_FRAME_MONITOR": "1",
    }
    if args.mode == "soak":
        env["ATTIC_PERF_SMOOTH"] = "1"
        env["ATTIC_SMOOTH_LONG"] = "1" if args.long else "0"
    if args.allocations:
        env["MallocStackLogging"] = "1"
    park_pointer()
    pid = None
    records = []
    try:
        run("/usr/bin/open", "-n", "--stdout", str(args.output.resolve() / "frames.log"),
            "--stderr", str(args.output.resolve() / "stderr.log"),
            *(arg for key, value in env.items() for arg in ("--env", f"{key}={value}")), str(app))
        initial = "smooth_ready" if args.mode == "soak" else "hidden_idle"
        marker = wait_for_phase(root, initial, timeout=90)
        pid = marker["pid"]
        executable = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "comm="], text=True).strip()
        if executable != str(app / "Contents/MacOS" / info["CFBundleExecutable"]):
            raise RuntimeError(f"Unexpected executable for probe PID {pid}")
        time.sleep(2)
        records.append({"phase": initial, **sample(pid)})
        print(json.dumps(records[-1]), flush=True)
        if args.mode == "reveal":
            os.kill(pid, signal.SIGUSR1)
            wait_for_phase(root, "tasks_open", pid=pid)
            records.append({"phase": "tasks_open", **sample(pid)})
            if args.allocations:
                allocation_summary(pid, args.output, "reveal")
        else:
            phases = ["smooth_tasks", "smooth_seeded"] + [f"smooth_visit_{n}" for n in range(1, 61)] + ["smooth_hidden"]
            for phase in phases:
                park_pointer()
                os.kill(pid, signal.SIGUSR1)
                marker = wait_for_phase(root, phase, timeout=180, pid=pid)
                record = {**marker, **sample(pid)}
                records.append(record)
                print(json.dumps(record), flush=True)
                if args.allocations and phase in {"smooth_seeded", "smooth_visit_15", "smooth_visit_30", "smooth_visit_45", "smooth_visit_60", "smooth_hidden"}:
                    allocation_summary(pid, args.output, phase)
                time.sleep(0.25)
        timings = [json.loads(line) for line in (root / "timings.ndjson").read_text().splitlines()]
        (args.output / "measurements.json").write_text(json.dumps({
            "app": str(app), "bundle": BUNDLE, "store": str(root), "records": records, "timings": timings,
        }, indent=2))
        if args.mode == "soak":
            check_retention(records)
            print("Retention gate passed: 60 visits, at most 8 engines, exactly 1 attached layout", flush=True)
        print(json.dumps({"first_reveal": next((row for row in timings if row["name"] == "PanelRevealToOrderedFront"), None),
                          "timing_count": len(timings)}), flush=True)
    finally:
        if pid is not None:
            run("/usr/bin/osascript", "-e", f'tell application id "{BUNDLE}" to quit')


if __name__ == "__main__":
    main()
