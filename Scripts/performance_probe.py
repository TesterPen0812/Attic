#!/usr/bin/env python3
"""Build a unique local-only preview, seed owned temporary stores, then probe.

The measured phase runs under the same machine-wide lock as xcodebuild. No
production bundle or store is ever opened. Baseline B: add --done-history. `--extra` adds unsampled phases after the
standard five (a warm reveal, page switches between built pages, add-bar
typing, a warm Tasks reveal); their timings carry a label prefix, so the
standard phases and timing names stay comparable with Baselines A and B.
"""

import argparse
import re
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / ".build" / "performance"
LOCK = "/tmp/attic-xcodebuild.lock"
WRAPPER = "/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh"


def command(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def wait_for_phase(root, expected, timeout=300, pid=None):
    deadline = time.monotonic() + timeout
    phase_file = root / "phase-markers" / f"{expected}.json"
    while time.monotonic() < deadline:
        try:
            latest = json.loads((root / "phase.json").read_text())
            if latest["phase"].endswith("_failed"):
                raise RuntimeError(f"Preview reported {latest}")
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        try:
            phase = json.loads(phase_file.read_text())
            if phase["phase"] == expected:
                return phase
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        if pid is not None and subprocess.run(["/bin/kill", "-0", str(pid)],
                                              stderr=subprocess.DEVNULL).returncode != 0:
            raise RuntimeError(f"Preview PID {pid} exited before {expected}")
        time.sleep(0.2)
    raise TimeoutError(f"No {expected} phase within {timeout}s; root={root}")


def process_sample(helper, pid):
    return json.loads(output(str(helper), str(pid)))


def footprint(pid, destination):
    command("/usr/bin/footprint", "-j", str(destination), "-p", str(pid),
            stdout=subprocess.DEVNULL)
    doc = json.loads(destination.read_text())
    processes = [item for item in doc["processes"] if item["pid"] == pid]
    if len(processes) != 1:
        raise RuntimeError(f"footprint did not identify PID {pid}")
    return processes[0]["footprint"]


def sample_phase(helper, pid, phase, seconds, run_dir):
    # Fixed quiet time keeps cold launch and post-hide transients out of idle.
    time.sleep(30 if phase in ("hidden_idle", "after_hide") else 2)
    before = process_sample(helper, pid)
    started = time.monotonic()
    first_footprint = footprint(pid, run_dir / f"{phase}-start-footprint.json")
    time.sleep(seconds)
    last_footprint = footprint(pid, run_dir / f"{phase}-end-footprint.json")
    elapsed = time.monotonic() - started
    after = process_sample(helper, pid)
    cpu_ns = (after["user_time_ns"] + after["system_time_ns"]
              - before["user_time_ns"] - before["system_time_ns"])
    wakeups = after["package_idle_wakeups"] - before["package_idle_wakeups"]
    return {
        "phase": phase, "duration_s": elapsed,
        "physical_footprint_bytes_start": first_footprint,
        "physical_footprint_bytes_end": last_footprint,
        "cpu_time_s": cpu_ns / 1e9, "cpu_percent_one_core": cpu_ns / 1e7 / elapsed,
        "package_idle_wakeups": wakeups,
        "package_idle_wakeups_per_s": wakeups / elapsed,
        "interrupt_wakeups": after["interrupt_wakeups"] - before["interrupt_wakeups"],
        "interrupt_wakeups_per_s": (after["interrupt_wakeups"] - before["interrupt_wakeups"]) / elapsed,
        "ps_time_end": output("/bin/ps", "-o", "time=", "-p", str(pid)),
    }


EXTRA_PHASES = ("warm_open", "switches_done", "typing_done", "tasks_hidden", "tasks_warm_open")


def launch(app, root, token, logs, seed=False, done=False, extra=False):
    env = {
        "ATTIC_UI_TESTING": "1",
        "ATTIC_UI_TEST_CANVAS_PERSISTENCE": "1",
        "ATTIC_PERF_STORE_ROOT": str(root),
        "ATTIC_PERF_OWNER_TOKEN": token,
        "ATTIC_PERF_SEED_ONLY": "1" if seed else "0",
        "ATTIC_PERF_DONE_HISTORY": "1" if done else "0",
        "ATTIC_PERF_PROBE": "0" if seed else "1",
        "ATTIC_PERF_EXTERNAL_CONTROL": "0" if seed else "1",
        "ATTIC_PERF_WINDOW_SECONDS": os.environ.get("ATTIC_PERF_WINDOW_SECONDS", "10"),
        "ATTIC_PERF_EXTRA": "1" if extra and not seed else "0",
    }
    command("/usr/bin/open", "-n", "--stdout", str(logs.with_suffix(".stdout.log")),
            "--stderr", str(logs.with_suffix(".stderr.log")),
            *(arg for pair in env.items() for arg in ("--env", f"{pair[0]}={pair[1]}")), str(app))


def build_preview(identity):
    BUILD.mkdir(parents=True, exist_ok=True)
    info = BUILD / "Info.plist"
    shutil.copy2(ROOT / "Attic" / "Info.plist", info)
    command("/usr/bin/plutil", "-replace", "CFBundleDisplayName", "-string",
            f"Attic Perf {identity}", str(info))
    name = f"AtticPerf{identity}"
    bundle = f"com.taha.Attic.perf.{identity}"
    derived = BUILD / "dd"
    flags = ["CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES",
             "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM="]
    build_command = WRAPPER if Path(WRAPPER).is_file() else "/usr/bin/xcodebuild"
    command(build_command, "build", "-project", "Attic.xcodeproj", "-scheme", "Attic",
            "-configuration", "Local", "-destination", "platform=macOS",
            "-derivedDataPath", str(derived), f"PRODUCT_BUNDLE_IDENTIFIER={bundle}",
            f"PRODUCT_NAME={name}", f"EXECUTABLE_NAME={name}",
            f"INFOPLIST_FILE={info}", "OTHER_SWIFT_FLAGS=$(inherited) -DATTIC_LOCAL_ONLY",
            *flags, cwd=ROOT, stdout=(BUILD / "preview-build.log").open("w"),
            stderr=subprocess.STDOUT)
    app = derived / "Build" / "Products" / "Local" / f"{name}.app"
    executable = app / "Contents" / "MacOS" / name
    if not executable.is_file():
        raise FileNotFoundError(executable)
    entitlements = subprocess.check_output(
        ["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(app)],
        stderr=subprocess.DEVNULL)
    parsed = plistlib.loads(entitlements)
    forbidden = [key for key in parsed if "icloud" in key.lower()
                 or "ubiquity" in key.lower() or key == "aps-environment"]
    if forbidden:
        raise RuntimeError(f"Preview contains deferred entitlements: {forbidden}")
    return app, executable, bundle


def initialize_container(app, executable):
    """Let LaunchServices create the unique sandbox before writing its fixture."""
    command("/usr/bin/open", "-n", "--env", "ATTIC_UI_TESTING=1",
            "--env", "ATTIC_PERF_SEED_ONLY=1", str(app))
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        for line in output("/bin/ps", "-axo", "pid=,command=").splitlines():
            columns = line.strip().split(maxsplit=1)
            if len(columns) == 2 and columns[1].startswith(str(executable)):
                pid = int(columns[0])
                command("/bin/kill", "-TERM", str(pid))
                return
        time.sleep(0.2)
    raise TimeoutError("Unique preview container did not initialize")


def measure(args, app, executable, bundle, helper):
    initialize_container(app, executable)
    results = []
    for run in range(1, args.runs + 1):
        run_dir = BUILD / f"run-{run}"
        run_dir.mkdir(parents=True, exist_ok=True)
        private_stores = (Path.home() / "Library" / "Containers" / bundle / "Data"
                          / "Library" / "Application Support" / "AtticPerformanceStores")
        private_stores.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="attic-perf-", dir=private_stores) as directory:
            root = Path(directory)
            token = secrets.token_hex(24)
            (root / ".attic-perf-owner").write_text(token)
            launch(app, root, token, run_dir / "seed", seed=True, done=args.done_history)
            seeding = wait_for_phase(root, "seeding", timeout=60)
            print(f"run {run}: seeding PID {seeding['pid']}", flush=True)
            seeded = wait_for_phase(root, "seed_complete", timeout=900, pid=seeding["pid"])
            print(f"run {run}: seed complete", flush=True)
            seed_pid = seeded["pid"]
            command("/bin/kill", "-TERM", str(seed_pid))
            for _ in range(100):
                if subprocess.run(["/bin/kill", "-0", str(seed_pid)],
                                  stderr=subprocess.DEVNULL).returncode != 0:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError(f"Seed process {seed_pid} did not exit")
            (root / "phase.json").unlink()
            shutil.rmtree(root / "phase-markers", ignore_errors=True)
            (root / "timings.ndjson").unlink(missing_ok=True)
            launch(app, root, token, run_dir / "probe", extra=args.extra)
            first = wait_for_phase(root, "hidden_idle")
            if first.get("panel_visible") != 0:
                raise RuntimeError(f"Panel was visible at hidden-idle marker: {first}")
            pid = first["pid"]
            print(f"run {run}: probing PID {pid}", flush=True)
            actual = output("/bin/ps", "-o", "command=", "-p", str(pid))
            if not actual.startswith(str(executable)):
                raise RuntimeError(f"Unexpected preview process: {actual}")
            phases = []
            try:
                for phase in ("hidden_idle", "tasks_open", "canvas_open", "after_hide", "hidden_idle_final"):
                    expected_visible = 0 if phase in ("hidden_idle", "after_hide", "hidden_idle_final") else 1
                    if phase != "hidden_idle":
                        marker = wait_for_phase(root, phase)
                        if marker["pid"] != pid:
                            raise RuntimeError("Preview process changed during probe")
                        if marker.get("panel_visible") != expected_visible:
                            raise RuntimeError(f"Panel visibility mismatch: {marker}")
                    else:
                        marker = first
                    if marker.get("hover_hidden") != 1 - expected_visible:
                        raise RuntimeError(f"Hover monitor state mismatch: {marker}")
                    if phase == "tasks_open" and marker.get("section_canvas") != 0:
                        raise RuntimeError(f"Tasks was not selected: {marker}")
                    if phase == "canvas_open" and (marker.get("section_canvas") != 1
                                                   or marker.get("visible_strokes") != 1700):
                        raise RuntimeError(f"Large canvas was not selected: {marker}")
                    sample = sample_phase(helper, pid, phase, args.window, run_dir)
                    command("/bin/kill", "-USR1", str(pid))
                    end = wait_for_phase(root, phase + "_end", timeout=30, pid=pid)
                    if end.get("panel_visible") != marker.get("panel_visible") or \
                       end.get("visibility_changes") != marker.get("visibility_changes") or \
                       end.get("hover_hidden") != marker.get("hover_hidden"):
                        raise RuntimeError(f"Panel visibility changed during {phase}: {marker} -> {end}")
                    sample["end_marker"] = end
                    phases.append(sample)
                if args.extra:
                    # The last standard USR1 already started the first extra
                    # phase; each later USR1 ends one and starts the next.
                    for index, phase in enumerate(EXTRA_PHASES):
                        if index > 0:
                            command("/bin/kill", "-USR1", str(pid))
                        wait_for_phase(root, phase, timeout=60, pid=pid)
                        time.sleep(1)
            finally:
                command("/bin/kill", "-TERM", str(pid))
            timing_file = root / "timings.ndjson"
            timings = [json.loads(line) for line in timing_file.read_text().splitlines()] \
                if timing_file.exists() else []
            names = [item["name"] for item in timings]
            for required, minimum in (("CoordinatorInitToMenuStarted", 1), ("StoreOpen", 1),
                                      ("PanelRevealToOrderedFront", 2), ("PageSwitch", 1)):
                if names.count(required) < minimum:
                    raise RuntimeError(f"Missing {required} timing in run {run}: {names}")
            (run_dir / "timings.ndjson").write_text(
                "".join(json.dumps(item) + "\n" for item in timings))
            results.append({"run": run, "pid": pid, "seed_pid": seed_pid,
                            "phases": phases, "timings": timings})
            print(f"run {run}/{args.runs} complete", flush=True)
    return results


def summarize(doc):
    lines = ["# Attic performance probe", "",
             f"Date: {doc['date']}", f"Commit: `{doc['commit']}`",
             f"Preview: `{doc['bundle_id']}`",
             f"Fixture: {'B, 5,000 Done tasks included' if doc['done_history'] else 'A, no extra Done history'}",
             "", "| Phase | Footprint end, MiB range | CPU, one-core % range | Interrupt wakeups/s range |",
             "| --- | ---: | ---: | ---: |"]
    for index, phase in enumerate(("hidden_idle", "tasks_open", "canvas_open", "after_hide", "hidden_idle_final")):
        values = [run["phases"][index] for run in doc["runs"]]
        def span(key, divisor=1):
            samples = [v[key] / divisor for v in values]
            return f"{min(samples):.2f}–{max(samples):.2f}"
        lines.append(f"| {phase} | {span('physical_footprint_bytes_end', 2**20)} | "
                     f"{span('cpu_percent_one_core')} | {span('interrupt_wakeups_per_s')} |")
    lines += ["", "CPU and interrupt wake-ups are process-counter deltas over each fixed window; "
              "footprint is Apple's physical footprint. Transition/settling time is excluded.", ""]
    standard = ("CoordinatorInitToMenuStarted", "StoreOpen", "PanelRevealToOrderedFront", "PageSwitch")
    labelled = sorted({entry["name"] for run in doc["runs"] for entry in run.get("timings", [])
                       if "." in entry["name"]})
    for name in standard + tuple(labelled):
        values = [entry["milliseconds"] for run in doc["runs"]
                  for entry in run.get("timings", []) if entry["name"] == name]
        if values:
            lines.append(f"{name}: {min(values):.2f}–{max(values):.2f} ms "
                         f"({len(values)} observations).")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--window", type=float, default=10)
    parser.add_argument("--done-history", action="store_true")
    parser.add_argument("--extra", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT / "Docs" / "performance-baseline-A.json")
    parser.add_argument("--measure", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--build-only", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--identity", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.runs < 1 or not 0 < args.window <= 12:
        parser.error("runs must be positive and window must be in (0, 12] seconds")
    identity = args.identity or secrets.token_hex(5)
    if not args.measure:
        build_preview(identity)
        if args.build_only:
            return
        return command("/usr/bin/lockf", "-k", LOCK, sys.executable, __file__,
                       "--measure", "--identity", identity, "--runs", str(args.runs),
                       "--window", str(args.window), *( ["--done-history"] if args.done_history else []),
                       *(["--extra"] if args.extra else []),
                       "--output", str(args.output))
    app = BUILD / "dd" / "Build" / "Products" / "Local" / f"AtticPerf{identity}.app"
    executable = app / "Contents" / "MacOS" / f"AtticPerf{identity}"
    bundle = f"com.taha.Attic.perf.{identity}"
    helper = BUILD / "perf_process_sample"
    command("/usr/bin/clang", "-O2", str(ROOT / "Scripts" / "perf_process_sample.c"),
            "-o", str(helper))
    container = Path.home() / "Library" / "Containers" / bundle
    if not re.fullmatch(r"[0-9a-f]{10}", identity):
        raise ValueError("The preview identity must be a generated ten-digit hex token")
    try:
        os.environ["ATTIC_PERF_WINDOW_SECONDS"] = str(args.window)
        runs = measure(args, app, executable, bundle, helper)
    finally:
        # Remove all probe-owned data. macOS protects its container-manager
        # metadata even from this user, so an empty system-managed shell may
        # remain; never let that permission error discard valid measurements.
        owned_stores = container / "Data" / "Library" / "Application Support" / "AtticPerformanceStores"
        if owned_stores.is_dir():
            shutil.rmtree(owned_stores)
        if container.is_dir():
            shutil.rmtree(container, ignore_errors=True)
            if container.exists():
                print(f"macOS container shell remains: {container}", file=sys.stderr)
    doc = {
        "schema": 2, "date": output("/bin/date", "-u", "+%Y-%m-%dT%H:%M:%SZ"),
        "commit": output("/usr/bin/git", "-C", str(ROOT), "rev-parse", "HEAD"),
        "branch": output("/usr/bin/git", "-C", str(ROOT), "branch", "--show-current"),
        "machine": output("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"),
        "os": output("/usr/bin/sw_vers", "-productVersion"),
        "xcode": plistlib.loads((Path(os.environ.get("DEVELOPER_DIR")
                                      or output("/usr/bin/xcode-select", "-p")).parent
                                  / "Info.plist").read_bytes()).get("CFBundleShortVersionString", "unknown"),
        "bundle_id": bundle, "executable": str(executable),
        # The no-history fixture is unchanged and remains comparable to A.
        "seed_version": 2 if args.done_history else 1,
        "seed_counts": {"tasks": 500, "notes": 200, "canvases": 20,
                                      "objects_per_canvas": 2000, "extra_done_tasks": 5000 if args.done_history else 0},
        "done_history": args.done_history, "extra_phases": args.extra, "window_s": args.window, "runs": runs,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(doc, indent=2) + "\n")
    args.output.with_suffix(".md").write_text(summarize(doc))
    print(summarize(doc))


if __name__ == "__main__":
    main()
