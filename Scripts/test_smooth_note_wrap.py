#!/usr/bin/env python3
"""Pure protocol checks for the measured Air gate; does not drive a screen."""
import copy
import json
import math
from pathlib import Path
import statistics
import unittest

from compare_note_wrap import compare, MEASURES


class NoteWrapGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.baseline = json.loads((Path(__file__).resolve().parents[1] / "Docs/performance-baseline-note-wrap.json").read_text())

    def test_recorded_baseline_is_accepted(self):
        rows, failures = compare(self.baseline, copy.deepcopy(self.baseline))
        self.assertEqual(failures, [])
        self.assertEqual(len(rows), 2)

    def test_cost_beyond_measured_spread_fails_without_a_fixed_target(self):
        candidate = copy.deepcopy(self.baseline)
        for metric in MEASURES:
            observed = [max(run[metric]) for run in self.baseline["runs"]]
            limit = statistics.median(observed) + max(observed) - min(observed)
            for run in candidate["runs"]:
                run[metric] = [math.nextafter(limit, math.inf)]
        _, failures = compare(self.baseline, candidate)
        self.assertEqual(set(failures), set(MEASURES))

    def test_different_machine_geometry_or_input_is_rejected(self):
        for key in ("machine", "window", "typing_pattern", "launch_seed", "observation"):
            candidate = copy.deepcopy(self.baseline)
            candidate[key] = "different"
            with self.assertRaises(ValueError):
                compare(self.baseline, candidate)

    def test_missing_or_nonfinite_wrap_measurement_is_rejected(self):
        for values in ([], [float("inf")], [float("nan")], [0], [-1]):
            candidate = copy.deepcopy(self.baseline)
            candidate["runs"][0][MEASURES[0]] = values
            with self.assertRaises(ValueError):
                compare(self.baseline, candidate)

    def test_incomplete_cohort_is_rejected(self):
        candidate = copy.deepcopy(self.baseline)
        candidate["runs"].pop()
        with self.assertRaises(ValueError):
            compare(self.baseline, candidate)


if __name__ == "__main__":
    unittest.main()
