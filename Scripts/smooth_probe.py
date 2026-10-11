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
    source = Path(__file__).with_name("perf_process_sample.c")
    if not helper.exists() or helper.stat().st_mtime_ns < source.stat().st_mtime_ns:
        run("/usr/bin/clang", str(source), "-o", str(helper))
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


def wait_for_owned_exit(pid, executable, timeout=15):
    """Keep the screen lock until LaunchServices' asynchronous quit finishes.

    A reused PID is not ours; never send it a signal or quit a second app.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="],
                                capture_output=True, text=True)
        if result.stdout.strip() != str(executable):
            return
        time.sleep(0.1)
    raise TimeoutError(f"Owned preview PID {pid} did not finish quitting")


def quit_owned_preview(pid, executable):
    """Recheck ownership at teardown; an exited/replaced PID is not ours."""
    actual = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="],
                            capture_output=True, text=True).stdout.strip()
    if actual != str(executable):
        return
    run("/usr/bin/osascript", "-e", f'tell application id "{BUNDLE}" to quit')
    wait_for_owned_exit(pid, executable)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["reveal", "soak"], default="reveal")
    parser.add_argument("--allocations", action="store_true")
    parser.add_argument("--long", action="store_true")
    parser.add_argument("--settle-seconds", type=float, default=2)
    parser.add_argument("--idle-sample-seconds", type=float, default=0)
    parser.add_argument("--frame-monitor", action=argparse.BooleanOptionalAction, default=None,
                        help="Default on for the soak, off for cold reveal (avoid prewarming it)")
    parser.add_argument("--reveal-breakdown", action="store_true",
                        help="Requires a stage-instrumented diagnostic build; standard previews do not emit stages")
    parser.add_argument("--reveal-counts", action="store_true",
                        help="Requires the diagnostic count overlay; excluded from timing acceptance")
    parser.add_argument("--capture-panel", action="store_true",
                        help="Capture only the verified preview PID, using the local window-id helper")
    parser.add_argument("--lldb-counts", action="store_true",
                        help="Count Swift-only environment/appearance/CA functions with LLDB; requires --reveal-counts")
    args = parser.parse_args()
    if args.lldb_counts and not args.reveal_counts:
        parser.error("--lldb-counts requires --reveal-counts")
    if args.reveal_counts and any((args.output / name).exists() for name in
                                 ("lldb-counts.ready", "lldb-counts.json", "reveal-counts.json", "measurements.json")):
        parser.error("Count captures require a fresh output directory")
    if not (0 <= args.settle_seconds <= 120 and 0 <= args.idle_sample_seconds <= 120):
        parser.error("settle and idle sample durations must be between 0 and 120 seconds")
    frames = args.frame_monitor if args.frame_monitor is not None else args.mode == "soak"
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
        "ATTIC_FRAME_MONITOR": "1" if frames else "0",
        "ATTIC_REVEAL_BREAKDOWN": "1" if args.reveal_breakdown else "0",
        "ATTIC_REVEAL_COUNTS": "1" if args.reveal_counts else "0",
    }
    if args.mode == "soak":
        env["ATTIC_PERF_SMOOTH"] = "1"
        env["ATTIC_SMOOTH_LONG"] = "1" if args.long else "0"
    if args.allocations:
        env["MallocStackLogging"] = "1"
    park_pointer()
    pid = None
    debugger = None
    debugger_log = None
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
        if args.lldb_counts:
            module = Path(__file__).with_name("reveal_lldb_counts.py").resolve()
            destination = args.output.resolve() / "lldb-counts.json"
            debugger_log = (args.output / "lldb.log").open("w")
            debugger = subprocess.Popen(["/usr/bin/xcrun", "lldb", "-b", "-p", str(pid),
                "-o", "command script import " + str(module),
                "-o", "script reveal_lldb_counts.start(lldb.debugger, " + repr(str(destination)) + ")",
                "-o", "process handle -p true -s false -n false SIGUSR1",
                "-o", "process continue", "-o", "script reveal_lldb_counts.finish_and_detach(lldb.debugger)"], stdout=debugger_log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 30
            while not destination.with_suffix(".ready").exists():
                if debugger.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("LLDB did not attach and install the count markers; inspect lldb.log")
                time.sleep(0.1)
        time.sleep(args.settle_seconds)
        records.append({"phase": initial, **sample(pid)})
        print(json.dumps(records[-1]), flush=True)
        if args.idle_sample_seconds:
            start = time.monotonic()
            time.sleep(args.idle_sample_seconds)
            records.append({"phase": "idle_sample_end", "elapsed_seconds": time.monotonic() - start, **sample(pid)})
            print(json.dumps(records[-1]), flush=True)
        if args.mode == "reveal":
            if debugger is not None and (args.output / "lldb-counts.json").exists():
                raise RuntimeError("Preview ordered before the commanded cold reveal; discard this run")
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
        if debugger is not None:
            debugger.wait(timeout=30)
            if debugger.returncode != 0:
                raise RuntimeError("LLDB count collection failed")
        if args.capture_panel:
            # Ordering is the measurement boundary; the 0.24-second reveal
            # animation finishes afterward. Capture its settled presentation.
            time.sleep(0.5)
            helper = Path(__file__).resolve().parent.parent / ".build/reveal-window-id"
            source = Path(__file__).with_name("reveal_window_id.swift")
            if not helper.exists() or helper.stat().st_mtime_ns < source.stat().st_mtime_ns:
                run("/usr/bin/xcrun", "swiftc", str(source), "-o", str(helper))
            if subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "comm="], text=True).strip() != str(app / "Contents/MacOS" / info["CFBundleExecutable"]):
                raise RuntimeError("Preview executable ownership changed before capture")
            window_id = subprocess.check_output([str(helper), str(pid)], text=True).strip()
            run("/usr/sbin/screencapture", "-x", "-o", "-l" + window_id, str(args.output / "panel.png"))
        if args.reveal_counts:
            counts = json.loads((root / "reveal-counts.json").read_text())
            if args.lldb_counts:
                counts["native_function_counts"] = json.loads((args.output / "lldb-counts.json").read_text())
            (args.output / "reveal-counts.json").write_text(json.dumps({
                "bundle": BUNDLE, "app": str(app), "counts": counts,
                "settings": {"mode": args.mode, "frame_monitor": frames,
                             "settle_seconds": args.settle_seconds, "idle_sample_seconds": args.idle_sample_seconds,
                             "allocations": args.allocations, "reveal_counts": True},
            }, indent=2))
        timings = [json.loads(line) for line in (root / "timings.ndjson").read_text().splitlines()]
        (args.output / "measurements.json").write_text(json.dumps({
            "app": str(app), "bundle": BUNDLE, "store": str(root), "records": records, "timings": timings,
            "settings": {"mode": args.mode, "frame_monitor": frames,
                         "settle_seconds": args.settle_seconds, "idle_sample_seconds": args.idle_sample_seconds,
                         "reveal_breakdown": args.reveal_breakdown, "reveal_counts": args.reveal_counts,
                         "allocations": args.allocations, "long_note": args.long},
        }, indent=2))
        if args.mode == "soak":
            check_retention(records)
            print("Retention gate passed: 60 visits, at most 8 engines, exactly 1 attached layout", flush=True)
        print(json.dumps({"first_reveal": next((row for row in timings if row["name"] == "PanelRevealToOrderedFront"), None),
                          "timing_count": len(timings)}), flush=True)
    finally:
        if debugger is not None and debugger.poll() is None:
            # Interrupt the debugger so its finally block detaches the
            # owned preview; application shutdown remains bundle-ID-only.
            debugger.send_signal(signal.SIGINT)
            debugger.wait(timeout=30)
        if debugger_log is not None:
            debugger_log.close()
        if pid is not None:
            quit_owned_preview(pid, app / "Contents/MacOS" / info["CFBundleExecutable"])


if __name__ == "__main__":
    main()
