#!/usr/bin/env python3
"""Focused parser regression, including incomplete and >500-ms traces."""
import json
import tempfile
import unittest
from pathlib import Path
from summarize_first_touch import load, one_touch, report
from contextlib import redirect_stdout
from io import StringIO


class FirstTouchSummaryTests(unittest.TestCase):
    def test_stall_stage_and_memory_matching(self):
        lines = [
            {"version": 1, "run": "test", "id": 7, "event": "input", "kind": "corner_approach",
             "atNS": 10_000_000_000, "originNS": 9_995_000_000,
             "idleMS": 120_000, "firstAfterIdle": True, "released": True},
            {"version": 1, "run": "test", "id": 7, "event": "stage", "stage": "reveal_decision", "atNS": 10_230_000_000},
            {"version": 1, "run": "test", "id": 7, "event": "stage", "stage": "handler_entered", "atNS": 10_001_000_000},
            {"version": 1, "run": "test", "id": 7, "event": "stage", "stage": "view_dispatch_done", "atNS": 10_420_000_000},
            {"version": 1, "run": "test", "id": 7, "event": "span", "stage": "page_layout",
             "spanStartNS": 10_231_000_000, "atNS": 10_415_000_000},
            {"version": 1, "run": "test", "id": 7, "event": "frame_candidate", "atNS": 10_630_000_000},
            {"version": 1, "run": "test", "id": 7, "event": "memory", "atNS": 10_010_000_000,
             "memory": {"valid": 3, "pageins": 200, "footprintBytes": 150, "residentBytes": 50, "compressedBytes": 30}},
            {"version": 1, "run": "test", "id": 7, "event": "memory", "atNS": 10_640_000_000,
             "memory": {"valid": 3, "pageins": 210, "footprintBytes": 150, "residentBytes": 60, "compressedBytes": 20}},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "first-touch.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in lines) + "\n")
            touch = one_touch(load(path)[0])
        self.assertEqual(touch["total"], 635)
        self.assertEqual(touch["stages"]["span:page_layout"], 184)
        self.assertEqual(touch["stages"]["callback_to_handler"], 1)
        self.assertEqual(touch["stages"]["handler_to_reveal_decision"], 229)
        self.assertEqual(touch["stages"]["reveal_to_view_dispatch"], 190)
        self.assertEqual(touch["pageins"], 10)
        self.assertTrue(touch["first"])

    def test_corrupted_last_line_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "first-touch.jsonl"
            path.write_text('{"version":1,"id":1,"event":"input","atNS":1}\n{"event":')
            self.assertEqual(len(load(path)), 1)

    def test_stall_without_a_frame_is_reported_as_observed_only(self):
        touch = one_touch([
            {"event": "input", "id": 2, "atNS": 2_000_000_000,
             "kind": "panel_control", "firstAfterIdle": True},
            {"event": "stage", "id": 2, "stage": "view_dispatch_done", "atNS": 2_601_000_000},
        ])
        self.assertIsNone(touch["total"])
        self.assertEqual(touch["observed_ms"], 601)
        output = StringIO()
        with redirect_stdout(output):
            report([touch])
        self.assertIn("Stalls >500ms to candidate or last recorded stage: 1", output.getvalue())
        self.assertIn("candidate_ms=None observed_ms=601", output.getvalue())

    def test_unrelated_late_stage_cannot_replace_original_handler(self):
        touch = one_touch([
            {"event": "input", "id": 7, "atNS": 1_000_000_000, "kind": "panel_control"},
            {"event": "stage", "id": 7, "stage": "handler_entered", "atNS": 1_000_010_000},
            {"event": "stage", "id": 7, "stage": "view_dispatch_done", "atNS": 1_085_000_000},
            {"event": "frame_candidate", "id": 7, "atNS": 1_100_000_000},
            {"event": "stage", "id": 7, "stage": "handler_entered", "atNS": 1_980_000_000},
        ])
        self.assertEqual(touch["stages"]["callback_to_handler"], 0.01)
        self.assertEqual(touch["total"], 100)

    def test_mouse_up_separates_press_from_action_dispatch_and_frame(self):
        touch = one_touch([
            {"event": "input", "id": 3, "atNS": 1_010_000_000,
             "originNS": 1_000_000_000, "kind": "panel_control"},
            {"event": "stage", "id": 3, "stage": "handler_entered", "atNS": 1_011_000_000},
            {"event": "mouse_up", "id": 3, "atNS": 1_132_000_000, "originNS": 1_120_000_000},
            {"event": "stage", "id": 3, "stage": "view_dispatch_done", "atNS": 1_140_000_000},
            {"event": "frame_candidate", "id": 3, "atNS": 1_175_000_000},
        ])
        self.assertEqual(touch["stages"]["press_duration"], 120)
        self.assertEqual(touch["stages"]["mouse_up_delivery"], 12)
        self.assertEqual(touch["stages"]["mouse_up_to_action_return"], 20)
        self.assertEqual(touch["stages"]["action_return_to_frame_candidate"], 35)
        self.assertEqual(touch["stages"]["mouse_up_to_frame_candidate"], 55)

    def test_corner_approach_time_is_not_attributed_to_reveal_dwell(self):
        touch = one_touch([
            {"event": "input", "id": 1, "atNS": 1_000_000_000,
             "kind": "corner_approach", "firstAfterIdle": True},
            {"event": "stage", "id": 1, "stage": "handler_entered", "atNS": 1_002_000_000},
            {"event": "stage", "id": 1, "stage": "followup_scheduled",
             "atNS": 1_470_000_000, "dueNS": 1_690_000_000},
            {"event": "stage", "id": 1, "stage": "reveal_decision", "atNS": 1_693_000_000},
            {"event": "frame_candidate", "id": 1, "atNS": 1_725_000_000},
        ])
        self.assertEqual(touch["stages"]["handler_to_reveal_decision"], 691)
        self.assertEqual(touch["stages"]["approach_to_hotspot_sample"], 468)
        self.assertEqual(touch["stages"]["hotspot_sample_to_followup_due"], 220)
        self.assertEqual(touch["stages"]["hotspot_sample_to_reveal_decision"], 223)


if __name__ == "__main__":
    unittest.main()
