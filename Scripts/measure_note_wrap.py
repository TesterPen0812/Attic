#!/usr/bin/env python3
"""Record a B-11 cohort on the Air, with an owned lock and an isolated preview.

Launches only com.taha.Attic.preview.sweep, with an environment allowlist and
in-memory UI fixtures. Captures only its window. --profile is diagnostic and
cannot supply a 100-key baseline to note_wrap_samples.py.
"""
import argparse
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess as sp
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=6)
    parser.add_argument("--width", type=int, choices=[320, 420], default=320)
    parser.add_argument("--words", action="store_true")
    parser.add_argument("--observe", action="store_true", help="diagnostic per-key AX reads")
    parser.add_argument("--rich", action="store_true")
    parser.add_argument("--tail", action="store_true")
    parser.add_argument("--long-seed", action="store_true")
    parser.add_argument("--profile", action="store_true")
    args = parser.parse_args()
    if sp.check_output(["hostname"], text=True).strip().lower() != "tahas-macbook-air.local":
        parser.error("Air-only capture; no app launched")
    owner = Path("/tmp/attic-air-screen.lockdir/owner")
    if owner.read_text().strip() != "sweep":
        parser.error("sweep must own the Air screen lock")
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    bid = "com.taha.Attic.preview.sweep"
    if info["CFBundleIdentifier"] != bid:
        parser.error("Expected the isolated sweep preview identity")
    if args.tail and not args.rich:
        parser.error("--tail requires --rich")
    if args.words and not (args.observe or args.profile):
        parser.error("Word diagnostics require --observe; the unobserved guard uses unbroken x input")
    if args.profile and args.runs != 1:
        parser.error("Use one diagnostic profile, separate from unprofiled cohorts")
    executable = args.app / "Contents/MacOS" / info["CFBundleExecutable"]
    # No inherited credentials reach the app, driver, log stream or profiler.
    clean = {k: os.environ[k] for k in ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG") if k in os.environ}
    clean["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    clean.update(ATTIC_UI_TESTING="1", ATTIC_UI_TEST_NONKEY_REVEAL="1",
                 ATTIC_UI_TEST_KEY_AFTER="0.5", ATTIC_UI_TEST_PAGE="notes",
                 ATTIC_UI_TEST_PINNED="1", ATTIC_UI_TEST_SET_WIDTH=f"0.1:{args.width}")
    if args.profile:
        clean["ATTIC_NOTE_WORK_PHASES"] = "1"
    if args.rich:
        clean["ATTIC_UI_TEST_NOTES_SCENE"] = "codex"
    if args.long_seed:
        clean["ATTIC_UI_TEST_SEED"] = "long"
    flags = [flag for enabled, flag in ((args.words, "--words"), (args.observe, "--observe"), (args.rich, "--rich"),
             (args.tail, "--tail"), (args.profile, "--repeat-wrap")) if enabled]
    for run in range(1, args.runs + 1):
        if owner.read_text().strip() != "sweep":
            raise RuntimeError("Screen ownership changed; no app launched")
        prefix = Path(f"{args.prefix}-{run}")
        trace = None
        with prefix.with_suffix(".runtime.log").open("w") as runtime, prefix.with_suffix(".signposts.jsonl").open("w") as logs:
            process = sp.Popen([str(executable), "-panelContentSize", "420", "-panelHeight", "640", "-animations", "lively"], env=clean, stdout=runtime, stderr=sp.STDOUT)
            stream = sp.Popen(["/usr/bin/log", "stream", "--style", "ndjson", "--signpost", "--predicate",
                              f'processIdentifier == {process.pid} AND subsystem == "com.taha.Attic"'],
                             env=clean, stdout=logs, stderr=sp.DEVNULL)
            try:
                time.sleep(5)
                if args.profile:
                    with prefix.with_suffix(".record.log").open("w") as record:
                        trace = sp.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--attach",
                            str(process.pid), "--time-limit", "22s", "--output", str(prefix.with_suffix(".trace")),
                            "--no-prompt"], env=clean, stdout=record, stderr=sp.STDOUT)
                    time.sleep(4)
                with prefix.with_suffix(".drive").open("w") as drive:
                    sp.run([str(args.driver), *flags], env=clean, stdout=drive, check=True)
                time.sleep(1)
                windows = re.findall(r"WINDOW id=(\d+) layer=3", prefix.with_suffix(".drive").read_text())
                if run == 1 and len(windows) == 1:
                    sp.run(["/usr/sbin/screencapture", "-x", "-l", windows[0], str(prefix.with_suffix(".png"))], env=clean, check=True)
                print(f"Completed run {run}", flush=True)
            finally:
                stream.terminate(); stream.wait(timeout=10)
                if trace:
                    if trace.poll() is None:
                        trace.send_signal(signal.SIGINT)
                    trace.wait(timeout=60)
                sp.run(["osascript", "-e", f'tell application id "{bid}" to quit'], env=clean,
                       stdout=sp.DEVNULL, stderr=sp.DEVNULL, timeout=15)
                process.wait(timeout=15)
        time.sleep(1)


if __name__ == "__main__":
    main()
