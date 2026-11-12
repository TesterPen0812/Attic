#!/usr/bin/env python3
"""Click-lag 4 preview capture analysis; never pools unfinished control samples."""
import argparse
import math
import statistics
from pathlib import Path

from summarize_first_touch import load, one_touch

METRICS = (
    "mouse_up_to_action_dispatch", "key_to_action_dispatch",
    "mouse_up_to_action_return", "view_to_commit_handoff",
    "action_dispatch_to_handoff", "handoff_to_frame_candidate",
    "mouse_up_to_frame_candidate",
)
CONTROLS = {
    "row-tick": ("row_tick",),
    "row-select": ("row_select",),
    "tag-filter": ("tag_filter",),
    "now-later": ("task_later", "task_now"),
    "now-done": ("task_done", "task_now"),
    "note-open-library": ("note_open", "note_library"),
    "note-format": ("note_format",),
    "calendar-day": ("calendar_day",),
    "calendar-event": ("calendar_event",),
    "calendar-view": ("calendar_view",),
    "draw-tool": ("draw_tool",),
    "draw-library": ("draw_library",),
    "draw-undo": ("draw_undo",),
    "add-bar": ("add_bar",),
}


def summary(values):
    if not values:
        return "n=0"
    values = sorted(values)
    return (f"n={len(values)} median={statistics.median(values):.2f} "
            f"p90={values[math.ceil(.9 * len(values)) - 1]:.2f} "
            f"worst={values[-1]:.2f}")


def cohorts(path):
    name = path.stem
    descriptor = next((key for key in CONTROLS if name.endswith(key)), None)
    if descriptor is None:
        return
    desired = CONTROLS[descriptor]
    touches = [one_touch(records) for records in load(path)]
    touches.sort(key=lambda touch: (touch["run"], touch["id"]))
    result = {}
    if descriptor in ("now-later", "now-done") and not any(
            touch["control"] in desired for touch in touches):
        # The first optimized preview predated separately labelled tabs.
        # It alternated destination -> Now for 20 iterations.
        tab_touches = [t for t in touches if t["control"] == "task_tab"][-40:]
        for offset, key in enumerate(desired):
            result[key] = tab_touches[offset::2][-20:]
    else:
        for key in desired:
            result[key] = [t for t in touches if t["control"] == key][-20:]
    return name, result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", type=Path)
    args = parser.parse_args()
    for path in sorted(args.captures.glob("*.jsonl")):
        group = cohorts(path)
        if group is None:
            continue
        name, controls = group
        for control, touches in controls.items():
            print(f"\n{name} {control}: {len(touches)}/20 confirmed input records")
            stages = sorted({key for touch in touches for key in touch["stages"]
                             if key.startswith("span:")})
            for stage in (*METRICS, *stages):
                values = [touch["stages"][stage] for touch in touches
                          if stage in touch["stages"]]
                if values:
                    print(f"  {stage}: {summary(values)}")
            counters = sorted({key for touch in touches for key in touch["counts"]})
            for counter in counters:
                values = [touch["counts"][counter] for touch in touches
                          if counter in touch["counts"]]
                print(f"  count:{counter}: {summary(values)}")


if __name__ == "__main__":
    main()
