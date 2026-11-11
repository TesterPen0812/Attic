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

    def test_labeled_control_measures_release_dispatch_handoff_and_frame(self):
        touch = one_touch([
            {"event": "input", "id": 6, "atNS": 1_000_000_000,
             "originNS": 990_000_000, "kind": "panel_control", "page": "tasks"},
            {"event": "mouse_up", "id": 6, "atNS": 1_105_000_000,
             "originNS": 1_100_000_000},
            {"event": "stage", "id": 6, "stage": "control_dispatched",
             "control": "row_tick", "atNS": 1_109_000_000},
            {"event": "stage", "id": 6, "stage": "view_dispatch_done", "atNS": 1_130_000_000},
            {"event": "stage", "id": 6, "stage": "commit_handoff", "atNS": 1_215_000_000},
            {"event": "frame_candidate", "id": 6, "atNS": 1_230_000_000},
        ])
        self.assertEqual(touch["control"], "row_tick")
        self.assertEqual(touch["stages"]["mouse_up_to_action_dispatch"], 9)
        self.assertEqual(touch["stages"]["action_dispatch_to_handoff"], 106)
        self.assertEqual(touch["stages"]["handoff_to_frame_candidate"], 15)

    def test_legacy_page_switch_is_only_known_identity(self):
        base = [
            {"event": "input", "id": 4, "atNS": 2_000_000_000,
             "kind": "island_action"},
            {"event": "mouse_up", "id": 4, "atNS": 2_105_000_000,
             "originNS": 2_100_000_000},
            {"event": "stage", "id": 4, "stage": "page_change_decision",
             "atNS": 2_112_000_000},
            {"event": "stage", "id": 4, "stage": "commit_handoff", "atNS": 2_170_000_000},
            {"event": "frame_candidate", "id": 4, "atNS": 2_185_000_000},
        ]
        switch = one_touch(base)
        self.assertEqual(switch["control"], "page_switch")
        self.assertEqual(switch["stages"]["mouse_up_to_action_dispatch"], 12)
        self.assertEqual(switch["stages"]["action_dispatch_to_handoff"], 58)
        unknown = one_touch([r for r in base if r.get("stage") != "page_change_decision"])
        self.assertEqual(unknown["control"], "island")
        self.assertNotIn("action_dispatch_to_handoff", unknown["stages"])

    def test_invalid_control_and_missing_boundaries_do_not_invent_stages(self):
        touch = one_touch([
            {"event": "input", "id": 9, "atNS": 1_000_000_000, "kind": "panel_control"},
            {"event": "stage", "id": 9, "stage": "control_dispatched",
             "control": "arbitrary_text", "atNS": 1_030_000_000},
            {"event": "frame_candidate", "id": 9, "atNS": 1_050_000_000},
            {"event": "stage", "id": 9, "stage": "control_dispatched",
             "control": "chat", "atNS": 1_060_000_000},
        ])
        self.assertIsNone(touch["control"])
        self.assertNotIn("mouse_up_to_action_dispatch", touch["stages"])
        self.assertNotIn("action_dispatch_to_handoff", touch["stages"])

    def test_first_action_marker_wins_when_trace_contains_multiple(self):
        trace = [
            {"event": "input", "id": 12, "atNS": 1_000_000_000,
             "kind": "panel_control"},
            {"event": "mouse_up", "id": 12, "atNS": 1_100_000_000,
             "originNS": 1_095_000_000},
            {"event": "stage", "id": 12, "stage": "control_dispatched",
             "control": "add_bar", "atNS": 1_110_000_000},
            {"event": "stage", "id": 12, "stage": "control_dispatched",
             "control": "settings", "atNS": 1_120_000_000},
            {"event": "stage", "id": 12, "stage": "commit_handoff", "atNS": 1_135_000_000},
            {"event": "frame_candidate", "id": 12, "atNS": 1_150_000_000},
        ]
        touch = one_touch(trace)
        self.assertEqual(touch["control"], "add_bar")
        self.assertEqual(touch["stages"]["action_dispatch_to_handoff"], 25)

    def test_small_control_cohorts_use_nearest_rank_p90(self):
        def touch(number, handoff_ms):
            start = 1_000_000_000
            return one_touch([
                {"event": "input", "id": number, "kind": "island_action", "atNS": start},
                {"event": "stage", "id": number, "stage": "commit_handoff",
                 "atNS": start + 100_000_000},
                {"event": "frame_candidate", "id": number,
                 "atNS": start + (100 + handoff_ms) * 1_000_000},
            ])
        output = StringIO()
        with redirect_stdout(output):
            report([touch(1, 7), touch(2, 25)])
        self.assertIn("p90=25.00 worst=25.00", output.getvalue())

    def test_keyboard_return_is_labelled_and_has_dispatch_and_stage_times(self):
        touch = one_touch([
            {"event": "input", "id": 17, "kind": "keyboard_control", "atNS": 1_000_000_000,
             "originNS": 990_000_000},
            {"event": "stage", "id": 17, "stage": "control_dispatched",
             "control": "add_bar", "atNS": 1_019_000_000},
            {"event": "span", "id": 17, "stage": "task_add_submit",
             "spanStartNS": 1_020_000_000, "atNS": 1_056_000_000},
            {"event": "counter", "id": 17, "stage": "task_save_changed_ids",
             "count": 1, "atNS": 1_043_000_000},
            {"event": "stage", "id": 17, "stage": "view_dispatch_done", "atNS": 1_060_000_000},
            {"event": "stage", "id": 17, "stage": "commit_handoff", "atNS": 1_085_000_000},
            {"event": "frame_candidate", "id": 17, "atNS": 1_101_000_000},
        ])
        self.assertEqual(touch["control"], "add_bar")
        self.assertEqual(touch["stages"]["key_to_action_dispatch"], 29)
        self.assertEqual(touch["stages"]["action_dispatch_to_handoff"], 66)
        self.assertEqual(touch["stages"]["span:task_add_submit"], 36)
        self.assertEqual(touch["counts"]["task_save_changed_ids"], 1)
        self.assertFalse(touch["mouse_up_recorded"])

    def test_new_controls_and_repeated_stage_counts_are_summarized(self):
        touch = one_touch([
            {"event": "input", "id": 18, "kind": "panel_control", "atNS": 1_000_000_000},
            {"event": "mouse_up", "id": 18, "atNS": 1_009_000_000,
             "originNS": 1_008_000_000},
            {"event": "stage", "id": 18, "stage": "control_dispatched",
             "control": "tag_filter", "atNS": 1_010_000_000},
            {"event": "span", "id": 18, "stage": "task_rows_build",
             "spanStartNS": 1_012_000_000, "atNS": 1_018_000_000},
            {"event": "span", "id": 18, "stage": "task_rows_build",
             "spanStartNS": 1_020_000_000, "atNS": 1_029_000_000},
            {"event": "counter", "id": 18, "stage": "task_rows_cache_miss",
             "count": 1, "atNS": 1_030_000_000},
            {"event": "counter", "id": 18, "stage": "task_rows_cache_miss",
             "count": 1, "atNS": 1_031_000_000},
            {"event": "counter", "id": 18, "stage": "task_rows", "count": 180,
             "atNS": 1_032_000_000},
            {"event": "stage", "id": 18, "stage": "commit_handoff", "atNS": 1_040_000_000},
            {"event": "frame_candidate", "id": 18, "atNS": 1_051_000_000},
        ])
        self.assertEqual(touch["control"], "tag_filter")
        self.assertEqual(touch["stages"]["span:task_rows_build"], 15)
        self.assertEqual(touch["counts"]["task_rows_cache_miss"], 2)
        self.assertEqual(touch["counts"]["task_rows"], 180)
        out = StringIO()
        with redirect_stdout(out):
            report([touch])
        self.assertIn("tag_filter: touches=1", out.getvalue())
        self.assertIn("span:task_rows_build: n=1 median=15.00", out.getvalue())
        self.assertIn("count:task_rows: n=1 median=180.00", out.getvalue())

    def test_every_named_control_is_in_report_even_when_not_measured(self):
        out = StringIO()
        with redirect_stdout(out):
            report([])
        for control in ("row_tick", "row_select", "add_bar", "add_bar_focus", "task_tab",
                        "task_now", "task_later", "task_done",
                        "tag_filter", "note_open", "note_format", "note_library", "calendar_day",
                        "calendar_event", "calendar_view", "draw_tool", "draw_library", "draw_undo"):
            self.assertIn(f"{control}: touches=0", out.getvalue())

    def test_task_tabs_are_reported_as_three_distinct_click_targets(self):
        samples = []
        for index, name in enumerate(("task_now", "task_later", "task_done"), start=1):
            samples.append(one_touch([
                {"event": "input", "id": index, "kind": "panel_control", "atNS": 1_000_000_000},
                {"event": "stage", "id": index, "stage": "control_dispatched", "control": name,
                 "atNS": 1_004_000_000},
                {"event": "stage", "id": index, "stage": "commit_handoff", "atNS": 1_018_000_000},
                {"event": "frame_candidate", "id": index, "atNS": 1_029_000_000},
            ]))
        out = StringIO()
        with redirect_stdout(out):
            report(samples)
        for name in ("task_now", "task_later", "task_done"):
            self.assertIn(f"{name}: touches=1", out.getvalue())


if __name__ == "__main__":
    unittest.main()
