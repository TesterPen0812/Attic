#!/usr/bin/env python3
"""Fixtures for the on-screen gate's analyzer (`perf_onscreen_analyze.py`):
only a valid, paired run counts, and an incomplete comparison fails.

    python3 Scripts/test_perf_onscreen_analyze.py
"""

import contextlib
import io
from datetime import datetime
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import perf_onscreen_analyze as analyzer

SCRIPT = Path(__file__).with_name("perf_onscreen_analyze.py")
WALL = 1_700_000_000.0  # the wall clock of the fixtures' first mark
MEDIA = 100.0  # and the media clock's


def stamp(t):
    return datetime.fromtimestamp(t).strftime("%Y/%m/%d %H:%M:%S")


def write_run(directory, label, *, gap=8.3, gpu=10, drive_exit=0, done=True, abort=None,
              marks=("scroll_start", "scroll_end", "swipe_start", "swipe_end"),
              input_seen=True, input_phases=("scroll", "swipe"), input_times=(1, 12),
              write_gpu=True, write_frames=True, frame_phases=("scroll", "swipe"), app_missing_in=()):
    """One run's files. Defaults make a valid run; each keyword breaks one
    part of it. `gap` is the frame gap in ms, `gpu` the device utilization."""
    base = Path(directory) / label
    times = {"scroll_start": 0, "scroll_end": 10, "swipe_start": 11, "swipe_end": 20}
    lines = [f"MARK {name} {MEDIA + times[name]:.4f} {WALL + times[name]:.3f}" for name in marks]
    if abort:
        lines.append(abort)
    elif done:
        lines.append("DONE")
    lines.append(f"ws=111 app=222 drive_exit={drive_exit}" if drive_exit is not None else "ws=111 app=222")
    base.with_suffix(".drive").write_text("\n".join(lines) + "\n")

    if write_frames:
        frames = ["ATTIC_FRAME_START refresh=120"]
        frames += [f"ATTIC_FRAME {MEDIA + 0.5 + 0.5 * i:.4f} {gap}" for i in range(40)
                   if ("scroll" if 0.5 + 0.5 * i <= 10 else "swipe") in frame_phases]
        if input_seen:
            if "scroll" in input_phases:
                frames.append(f"ATTIC_EVENT {MEDIA + input_times[0]} scroll-began")
            if "swipe" in input_phases:
                frames.append(f"ATTIC_EVENT {MEDIA + input_times[1]} settle-end 1")
        base.with_suffix(".frames").write_text("\n".join(frames) + "\n")

    top = []
    for i in range(6):  # the first sample is skipped by the analyzer
        top += [f"Processes: 700 total", stamp(WALL + 2 + i), "Load Avg: 1", "PID COMMAND %CPU"]
        if i not in app_missing_in:
            top.append("222  Attic Preview 4.0")
        top.append("111  WindowServer 2.0")
        top.append("")
    base.with_suffix(".top").write_text("\n".join(top))

    if write_gpu:
        gpu_lines = [f'GPU {WALL + 1 + i:.3f} "Device Utilization %"={gpu} "Renderer Utilization %"={gpu} '
                     for i in range(18)]
        base.with_suffix(".gpu").write_text("\n".join(gpu_lines) + "\n")
    else:
        base.with_suffix(".gpu").unlink(missing_ok=True)


def report(directory, rounds=2, **options):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = analyzer.main(str(directory), "baseline", "candidate", rounds, **options)
    return code, out.getvalue()


class AnalyzerTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def write_pairs(self, candidate_overrides=None, baseline_overrides=None, rounds=2):
        for n in range(1, rounds + 1):
            write_run(self.dir, f"baseline-{n}", **{"gpu": 10, **(baseline_overrides or {}).get(n, {})})
            write_run(self.dir, f"candidate-{n}", **{"gpu": 14, **(candidate_overrides or {}).get(n, {})})

    def test_valid_runs_give_a_complete_comparison(self):
        self.write_pairs()
        code, text = report(self.dir)
        self.assertEqual(code, 0, text)
        self.assertIn("COMPLETE", text)
        self.assertIn("+4.0", text)  # GPU mean 14 vs 10
        self.assertNotIn("INVALID", text)

    def test_an_aborted_run_is_excluded_and_the_comparison_is_incomplete(self):
        # Covered after scrolling, before swiping finished: the driver aborts
        # with exit 4, low GPU use, and no swipe_end mark.
        self.write_pairs(candidate_overrides={2: dict(
            drive_exit=4, gpu=1, abort="ABORT: another window covers the panel",
            marks=("scroll_start", "scroll_end", "swipe_start"))})
        code, text = report(self.dir)
        self.assertEqual(code, 1, text)
        self.assertIn("INCOMPLETE", text)
        self.assertIn("INVALID: the driver exited 4", text)
        self.assertIn("ABORT: another window covers the panel", text)
        self.assertIn("no swipe_end mark", text)
        self.assertNotIn("COMPLETE, ", text)
        # No mean or delta is printed, so the aborted run cannot pull one.
        self.assertNotIn("Candidate − baseline", text)

    def test_a_locked_screen_run_with_no_input_does_not_count(self):
        # The driver "finishes" (the events went nowhere), the GPU idles and
        # the app echoed nothing.
        self.write_pairs(baseline_overrides={1: dict(input_seen=False, gpu=0)})
        code, text = report(self.dir)
        self.assertEqual(code, 1, text)
        self.assertIn("baseline-1", text)
        self.assertIn("no input reached the app", text)
        self.assertIn("INCOMPLETE", text)

    def test_a_run_missing_scroll_input_does_not_count(self):
        self.write_pairs(candidate_overrides={1: dict(input_phases=("swipe",))})
        code, text = report(self.dir)
        self.assertEqual(code, 1, text)
        self.assertIn("no input reached the app in the scroll phase", text)
        self.assertNotIn("no input reached the app in the swipe phase", text)
        self.assertIn("INCOMPLETE", text)
        self.assertNotIn("Candidate − baseline", text)

    def test_a_run_missing_swipe_input_does_not_count(self):
        self.write_pairs(candidate_overrides={1: dict(input_phases=("scroll",))})
        code, text = report(self.dir)
        self.assertEqual(code, 1, text)
        self.assertIn("no input reached the app in the swipe phase", text)
        self.assertNotIn("no input reached the app in the scroll phase", text)
        self.assertIn("INCOMPLETE", text)
        self.assertNotIn("Candidate − baseline", text)

    def test_pre_phase_one_baseline_requires_explicit_flag_and_is_labelled(self):
        self.write_pairs(baseline_overrides={n: dict(input_phases=("swipe",)) for n in (1, 2)})
        code, text = report(self.dir)
        self.assertEqual(code, 1, text)
        self.assertIn("no input reached the app in the scroll phase", text)
        done = subprocess.run([sys.executable, str(SCRIPT), str(self.dir), "baseline", "candidate",
                               "--baseline-no-scroll-echo"], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        rows = [line for line in done.stdout.splitlines() if line.startswith(("| baseline-", "Comparison:"))]
        self.assertEqual(len(rows), 3)
        self.assertTrue(all("scroll input unverified (baseline)" in row for row in rows))
        self.assertNotIn("scroll input unverified (candidate)", done.stdout)
        self.assertIn("+4.0", done.stdout)

    def test_scroll_echo_flags_apply_only_to_the_selected_side(self):
        for side in ("baseline", "candidate"):
            with self.subTest(side=side):
                self.write_pairs(**{f"{side}_overrides": {1: dict(input_phases=("swipe",))}})
                wrong = "candidate" if side == "baseline" else "baseline"
                code, text = report(self.dir, **{f"{wrong}_no_scroll_echo": True})
                self.assertEqual(code, 1, text)
                done = subprocess.run([sys.executable, str(SCRIPT), str(self.dir), "baseline", "candidate",
                                       f"--{side}-no-scroll-echo"], capture_output=True, text=True)
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertIn(f"scroll input unverified ({side})", done.stdout)

    def test_flag_does_not_waive_an_echo_outside_scroll_or_other_missing_evidence(self):
        cases = [
            (dict(input_times=(-1, 12)), "no input reached the app in the scroll phase"),
            (dict(input_times=(12, 12)), "no input reached the app in the scroll phase"),
            (dict(input_times=(21, 12)), "no input reached the app in the scroll phase"),
            (dict(input_seen=False), "no input reached the app in the swipe phase"),
            (dict(input_phases=("swipe",), input_times=(1, 21)), "no input reached the app in the swipe phase"),
            (dict(input_phases=("swipe",), frame_phases=("swipe",)), "no frames in the scroll phase"),
            (dict(input_phases=("swipe",), write_gpu=False), "no GPU samples"),
        ]
        for overrides, problem in cases:
            with self.subTest(overrides=overrides):
                self.write_pairs(baseline_overrides={1: overrides})
                code, text = report(self.dir, baseline_no_scroll_echo=True)
                self.assertEqual(code, 1, text)
                self.assertIn(problem, text)
                self.assertNotIn("Candidate − baseline", text)

    def test_flag_does_not_label_a_build_with_verified_scroll_input(self):
        self.write_pairs()
        code, text = report(self.dir, baseline_no_scroll_echo=True, candidate_no_scroll_echo=True)
        self.assertEqual(code, 0, text)
        self.assertNotIn("unverified", text)

    def test_echoes_outside_their_own_phase_windows_do_not_count(self):
        for phase, times in [("scroll", (-1, 12)), ("scroll", (12, 12)),
                             ("swipe", (1, 10)), ("swipe", (1, 21))]:
            with self.subTest(phase=phase, times=times):
                self.write_pairs(candidate_overrides={1: dict(input_times=times)})
                code, text = report(self.dir)
                self.assertEqual(code, 1, text)
                self.assertIn(f"no input reached the app in the {phase} phase", text)
                self.assertIn("INCOMPLETE", text)

    def test_a_run_with_a_missing_gpu_file_does_not_count(self):
        self.write_pairs(candidate_overrides={1: dict(write_gpu=False)})
        code, text = report(self.dir)
        self.assertEqual(code, 1, text)
        self.assertIn("no GPU samples", text)
        self.assertIn("INCOMPLETE", text)

    def test_an_interrupted_run_has_no_exit_status(self):
        self.write_pairs(candidate_overrides={2: dict(drive_exit=None, done=False)})
        code, text = report(self.dir)
        self.assertEqual(code, 1, text)
        self.assertIn("the driver left no exit status", text)

    def test_a_run_with_no_frames_does_not_count(self):
        self.write_pairs(baseline_overrides={2: dict(write_frames=False)})
        code, text = report(self.dir)
        self.assertEqual(code, 1, text)
        self.assertIn("no frames in the scroll phase", text)
        self.assertIn("no input reached the app", text)

    def test_an_invalid_run_is_left_out_of_the_means(self):
        # Three rounds required two: round 2's candidate run is invalid, so
        # rounds 1 and 3 are the pairs, and its gpu=1 changes nothing.
        self.write_pairs(rounds=3, candidate_overrides={2: dict(drive_exit=4, gpu=1)})
        code, text = report(self.dir, rounds=2)
        self.assertEqual(code, 0, text)
        self.assertIn("COMPLETE, 2 paired valid rounds (1, 3)", text)
        candidate_row = next(line for line in text.splitlines() if line.startswith("| candidate |"))
        self.assertIn("14.0 (±0.0)", candidate_row)
        self.assertIn("INVALID: the driver exited 4", text)

    def test_a_missing_cpu_sample_is_a_missing_value_not_zero(self):
        for label in ("baseline-1", "candidate-1"):
            write_run(self.dir, label, app_missing_in=(1, 2, 3))
        result = analyzer.analyse(str(self.dir / "baseline-1"))
        self.assertTrue(result["valid"], result["problems"])
        self.assertAlmostEqual(result["app_cpu"][0], 4.0)  # not dragged down by zeros
        # With no sample of the app at all, the value is missing, and the run still counts.
        write_run(self.dir, "baseline-2", app_missing_in=range(6))
        none = analyzer.analyse(str(self.dir / "baseline-2"))
        self.assertNotIn("app_cpu", none)
        self.assertEqual(dict(analyzer.metrics(none))["app CPU %"], None)
        self.assertTrue(none["valid"], none["problems"])

    def test_an_earlier_invocations_files_cannot_complete_an_aborted_one(self):
        # The gate gives each invocation its own new directory under --out
        # (<out>/<time>-<pid>) and the analyzer reads only the one it is given.
        # An earlier, successful three-round comparison sits in the parent;
        # this invocation (two rounds requested) aborted at candidate-1.
        self.write_pairs(rounds=3)
        child = self.dir / "20261002-101500-4242"
        child.mkdir()
        write_run(child, "baseline-1")
        write_run(child, "candidate-1", drive_exit=4, abort="ABORT: another window covers the panel",
                  marks=("scroll_start",))
        code, text = report(child, rounds=2)
        self.assertEqual(code, 1, text)
        self.assertIn("INCOMPLETE", text)
        self.assertNotIn("candidate-2", text)
        self.assertNotIn("baseline-3", text)
        # Reading the parent as one directory would have said COMPLETE from
        # the old rounds: the reason the gate never does.
        code, _ = report(self.dir, rounds=2)
        self.assertEqual(code, 0)

    def test_the_command_exits_nonzero_for_an_incomplete_comparison(self):
        self.write_pairs(candidate_overrides={1: dict(drive_exit=4)})
        done = subprocess.run([sys.executable, str(SCRIPT), str(self.dir), "baseline", "candidate", "--rounds", "2"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("INCOMPLETE", done.stdout)


if __name__ == "__main__":
    unittest.main()
