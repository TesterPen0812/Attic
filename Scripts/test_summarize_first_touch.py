#!/usr/bin/env python3
"""Focused parser regression, including incomplete and >500-ms traces."""
import json
import tempfile
import unittest
from pathlib import Path
from summarize_first_touch import load, one_touch


class FirstTouchSummaryTests(unittest.TestCase):
    def test_stall_stage_and_memory_matching(self):
        lines = [
            {"version": 1, "run": "test", "id": 7, "event": "input", "kind": "corner_approach",
             "atNS": 10_000_000_000, "originNS": 9_995_000_000,
             "idleMS": 120_000, "firstAfterIdle": True, "released": True},
            {"version": 1, "run": "test", "id": 7, "event": "stage", "stage": "reveal_decision", "atNS": 10_230_000_000},
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
        self.assertEqual(touch["stages"]["callback_to_handler"], 230)
        self.assertEqual(touch["pageins"], 10)
        self.assertTrue(touch["first"])

    def test_corrupted_last_line_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "first-touch.jsonl"
            path.write_text('{"version":1,"id":1,"event":"input","atNS":1}\n{"event":')
            self.assertEqual(len(load(path)), 1)


if __name__ == "__main__":
    unittest.main()
