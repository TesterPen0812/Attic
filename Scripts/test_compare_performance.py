#!/usr/bin/env python3
"""Focused checks for the same-run performance comparison rule."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from compare_performance import PHASES, TIMINGS, timing_series


SCRIPT = Path(__file__).with_name("compare_performance.py")


def document(primary=None):
    runs = []
    for number in range(1, 7):
        phases = []
        for name in PHASES:
            phases.append({
                "phase": name,
                "physical_footprint_bytes_end": 2 if primary == f"{name} footprint" else 1,
                "cpu_percent_one_core": 2 if primary == f"{name} CPU" else 1,
                "interrupt_wakeups": 2 if primary == f"{name} interrupt wake-ups" else 1,
                "duration_s": 1,
            })
        timings = [{"name": name, "milliseconds": 2 if primary == name else 1}
                   for name in TIMINGS]
        timings.append({"name": "PanelRevealToOrderedFront", "milliseconds": 100})
        runs.append({"run": number, "phases": phases, "timings": timings})
    return {"schema": 2, "machine": "test", "os": "test", "xcode": "test",
            "seed_version": 1, "seed_counts": {}, "done_history": False,
            "window_s": 1, "runs": runs}


class ComparisonTests(unittest.TestCase):
    def test_different_seed_versions_are_incomparable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reference = root / "reference.json"
            candidate = root / "candidate.json"
            reference.write_text(json.dumps(document()))
            changed = document()
            changed["seed_version"] = 2
            candidate.write_text(json.dumps(changed))

            result = subprocess.run([sys.executable, str(SCRIPT), str(reference), str(candidate)],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Incomparable seed_version", result.stderr)

    def test_first_reveal_is_selected_even_when_later_event_is_slower(self):
        self.assertEqual(timing_series(document(), "PanelRevealToOrderedFront"), [1] * 6)

    def test_complete_separation_and_same_measure_confirmation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reference = root / "reference.json"
            first = root / "first.json"
            other = root / "other.json"
            repeat = root / "repeat.json"
            first_report = root / "first-regressions.json"
            reference.write_text(json.dumps(document()))
            first.write_text(json.dumps(document("hidden_idle CPU")))
            other.write_text(json.dumps(document("after_hide footprint")))
            repeat.write_text(json.dumps(document("hidden_idle CPU")))

            initial = subprocess.run([sys.executable, str(SCRIPT), str(reference), str(first),
                                      "--regressions-json", str(first_report)],
                                     text=True, capture_output=True)
            self.assertNotEqual(initial.returncode, 0)
            self.assertEqual(json.loads(first_report.read_text()), ["hidden_idle CPU"])

            unrelated = subprocess.run([sys.executable, str(SCRIPT), str(reference), str(other),
                                        "--require-common-with", str(first_report)],
                                       text=True, capture_output=True)
            self.assertEqual(unrelated.returncode, 0)
            self.assertNotIn("::warning::", unrelated.stdout)

            confirmed = subprocess.run([sys.executable, str(SCRIPT), str(reference), str(repeat),
                                        "--require-common-with", str(first_report)],
                                       text=True, capture_output=True)
            self.assertNotEqual(confirmed.returncode, 0)
            self.assertIn("::warning::Confirmed performance separation in hidden_idle CPU",
                          confirmed.stdout)


if __name__ == "__main__":
    unittest.main()
