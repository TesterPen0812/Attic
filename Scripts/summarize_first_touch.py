#!/usr/bin/env python3
"""Summarize a Local preview's bounded Attic/Diagnostics/first-touch.jsonl.

Per-touch monotonic stages are best-effort. A CADisplayLink callback is a frame
candidate, not proven scan-out, and CA/WindowServer times require a system trace.
"""
import argparse
import collections
import json
import math
import statistics
from pathlib import Path

KNOWN_CONTROLS = (
    "row_tick", "row_select", "add_bar", "add_bar_focus", "task_tab", "task_now",
    "task_later", "task_done", "tag_filter",
    "note_open", "note_format", "note_library", "calendar_day", "calendar_event",
    "calendar_view", "draw_tool", "draw_library", "draw_undo", "page_switch",
    "chat", "settings", "island",
)
INCREMENT_COUNTERS = {"task_reload_count", "task_rows_cache_miss", "task_rows_cache_hit",
                      "calendar_rebuild_pass"}


def load(path):
    groups = {}
    for line in path.read_text().splitlines():
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue  # tolerate an interrupted final append
        if entry.get("version") != 1 or not isinstance(entry.get("id"), int):
            continue
        key = (entry.get("run", "legacy"), entry["id"])
        group = groups.setdefault(key, [])
        group.append(entry)
    return [records for records in groups.values() if any(r["event"] == "input" for r in records)]


def ms_between(start, end):
    return round((end - start) / 1_000_000, 2) if start is not None and end is not None and end >= start else None


def one_touch(records):
    first = next(r for r in records if r["event"] == "input")
    frames = [r["atNS"] for r in records if r["event"] == "frame_candidate"]
    candidate = min(frames) if frames else None
    # A trace once stayed current after its first frame. Later untraced mouse
    # downs wrote extra handler_entered records against the old touch. Keep
    # the FIRST occurrence of each boundary, and never read beyond the frame.
    stages = {}
    spans = collections.defaultdict(float)
    counts = {}
    control_events = []
    for r in sorted(records, key=lambda r: r["atNS"]):
        if candidate is not None and r["atNS"] > candidate:
            continue
        if r["event"] == "stage":
            stages.setdefault(r.get("stage"), r["atNS"])
            if r.get("stage") == "control_dispatched" and r.get("control") in KNOWN_CONTROLS:
                control_events.append(r)
        elif r["event"] == "span":
            elapsed = ms_between(r.get("spanStartNS"), r["atNS"])
            if elapsed is not None:
                spans[r["stage"]] += elapsed
        elif r["event"] == "counter" and isinstance(r.get("count"), int):
            # Event counters accumulate; snapshot counters report the last
            # observed size/state without double counting repeated reads.
            name = r.get("stage")
            if name in INCREMENT_COUNTERS:
                counts[name] = counts.get(name, 0) + r["count"]
            else:
                counts[name] = r["count"]
    ups = sorted((r for r in records if r["event"] == "mouse_up"
                  and (candidate is None or r["atNS"] <= candidate)), key=lambda r: r["atNS"])
    mouse_up = ups[0] if ups else None
    # A page-switch decision is the only action-start marker in the owner's
    # older log. Other panel controls cannot be identified from that log.
    # The first accepted action owns this touch; a later nested action
    # must not reclassify it or shorten dispatch -> handoff.
    control = (control_events[0]["control"] if control_events else
               "page_switch" if "page_change_decision" in stages else
               "island" if first.get("kind") == "island_action" else None)
    action_dispatch = (control_events[0]["atNS"] if control_events else
                       stages.get("page_change_decision") if control == "page_switch" else None)
    scheduled = next((r for r in sorted(records, key=lambda r: r["atNS"])
                      if r.get("stage") == "followup_scheduled"
                      and (candidate is None or r["atNS"] <= candidate)), None)
    hotspot = next((r for r in records if r["event"] == "stage"
                    and r.get("stage") == "hotspot_entered"), None)
    input_ns = first["atNS"]
    origin = first.get("originNS", input_ns)
    up_origin = mouse_up.get("originNS", mouse_up["atNS"]) if mouse_up else None
    # The synchronous AppKit/SwiftUI action delivery has returned by this
    # boundary; an async action can continue afterwards. A native tracking
    # loop can consume mouse-up inside mouseDown, returning on mouse-down.
    action_return = stages.get("view_dispatch_done")
    if up_origin is not None and (action_return is None or action_return < up_origin):
        action_return = stages.get("mouse_down_returned")
    if action_return is not None and up_origin is not None and action_return < up_origin:
        action_return = None
    parts = {}
    boundaries = [
        ("event_delivery", origin, input_ns),
        ("callback_to_handler", input_ns, stages.get("handler_entered") or stages.get("reveal_decision")),
        ("handler_to_reveal_decision", stages.get("handler_entered"), stages.get("reveal_decision")),
        ("approach_to_hotspot", stages.get("handler_entered"), stages.get("hotspot_entered")),
        ("hotspot_to_reveal_decision", stages.get("hotspot_entered"), stages.get("reveal_decision")),
        ("reveal_to_view_dispatch", stages.get("reveal_decision"), stages.get("view_dispatch_done")),
        ("handler_to_down_return", stages.get("handler_entered"), stages.get("mouse_down_returned")),
        ("down_to_view_dispatch", stages.get("mouse_down_returned"), stages.get("view_dispatch_done")),
        ("view_to_commit_handoff", stages.get("view_dispatch_done"), stages.get("commit_handoff") or stages.get("transaction_flushed")),
        ("action_dispatch_to_handoff", action_dispatch, stages.get("commit_handoff") or stages.get("transaction_flushed")),
        ("view_to_transaction_flush", stages.get("view_dispatch_done"), stages.get("transaction_flushed")),
        ("handoff_to_frame_candidate", stages.get("commit_handoff") or stages.get("transaction_flushed"), candidate),
    ]
    if first.get("kind") == "corner_approach":
        scheduled_at = scheduled["atNS"] if scheduled else None
        boundaries.extend([
            # The approach trace begins at 96 pt from the corner. The first
            # reveal follow-up is scheduled only once the actual hotspot is
            # reached; this pre-dwell interval includes pointer travel.
            ("approach_to_hotspot_sample", stages.get("handler_entered"), scheduled_at),
            ("hotspot_sample_to_reveal_decision", scheduled_at, stages.get("reveal_decision")),
            ("hotspot_sample_to_followup_due", scheduled_at, scheduled.get("dueNS") if scheduled else None),
        ])
    if first.get("kind") in ("panel_control", "island_action"):
        boundaries.extend([
            ("press_duration", origin, up_origin),
            ("mouse_up_delivery", up_origin, mouse_up["atNS"] if mouse_up else None),
            ("mouse_up_to_action_return", up_origin, action_return),
            ("mouse_up_to_action_dispatch", up_origin, action_dispatch),
            ("action_return_to_frame_candidate", action_return, candidate),
            ("mouse_up_to_frame_candidate", up_origin, candidate),
        ])
    if first.get("kind") == "keyboard_control":
        boundaries.append(("key_to_action_dispatch", origin, action_dispatch))
    if first.get("kind") == "island_wake":
        boundaries.append(("handler_to_view_dispatch", stages.get("handler_entered"), stages.get("view_dispatch_done")))
    for name, begin, end in boundaries:
        value = ms_between(begin, end)
        if value is not None:
            parts[name] = value
    for name, elapsed in spans.items():
        if elapsed is not None:
            parts["span:" + name] = elapsed
    if "followup_fired" in stages:
        fired = next((r for r in records if r.get("stage") == "followup_fired"), None)
        if fired:
            parts["followup_late"] = ms_between(fired.get("dueNS"), fired["atNS"])
    parts = {k: v for k, v in parts.items() if v is not None}
    # If no display-link callback arrived, an observed stage may itself prove
    # a >500 ms delay. Ignore asynchronous memory records for that judgement.
    observed = [r["atNS"] for r in records
                if r["event"] in ("stage", "span", "frame_candidate")
                and (candidate is None or r["atNS"] <= candidate)]
    observed_ms = ms_between(origin, max(observed)) if observed else None
    memory = [r for r in records if r["event"] == "memory" and r.get("memory")]
    memory.sort(key=lambda r: r["atNS"])
    pageins = None
    if len(memory) > 1 and (memory[0]["memory"]["valid"] & memory[-1]["memory"]["valid"] & 2):
        pageins = max(0, memory[-1]["memory"]["pageins"] - memory[0]["memory"]["pageins"])
    return {
        "kind": first.get("kind", "unknown"),
        "control": control,
        "page": first.get("page"),
        "first": bool(first.get("firstAfterIdle")),
        "idle_ms": first.get("idleMS"),
        "hidden_ms": first.get("hiddenMS"),
        "total": ms_between(origin, candidate),
        "observed_ms": observed_ms,
        "stages": parts,
        "counts": counts,
        "released": first.get("released"),
        "nap_activity": first.get("napActivity"),
        "configured_reveal_delay_ms": hotspot.get("revealDelayMS") if hotspot else None,
        "mouse_up_recorded": mouse_up is not None,
        "pageins": pageins,
        "memory": [r["memory"] for r in memory],
        "id": first["id"],
        "run": first.get("run", "legacy"),
    }


def report(touches):
    print(f"Touches: {len(touches)} (frame = next display-link callback; presentation/scan-out unverified)")
    report_controls(touches)
    cohorts = collections.defaultdict(list)
    for item in touches:
        cohorts[(item["kind"], "first" if item["first"] else "repeat")].append(item)
    for (kind, label), entries in sorted(cohorts.items()):
        totals = [item["total"] for item in entries if item["total"] is not None]
        biggest = max(((value, key) for item in entries for key, value in item["stages"].items()), default=(0, "unmeasured"))
        median = f"{statistics.median(totals):.2f}" if totals else "no candidate"
        print(f"{kind:18s} {label:6s} n={len(entries)} candidate_median_ms={median} "
              f"slowest_observed_stage={biggest[1]}:{biggest[0]:.2f}ms missing_frame={len(entries)-len(totals)}")
        if kind in ("panel_control", "island_action"):
            for key in ("press_duration", "mouse_up_to_action_return", "action_return_to_frame_candidate",
                        "mouse_up_to_frame_candidate"):
                measured = [item["stages"][key] for item in entries if key in item["stages"]]
                if measured:
                    print(f"  {key}: median={statistics.median(measured):.2f}ms "
                          f"worst={max(measured):.2f}ms n={len(measured)}")
            if not any(item["mouse_up_recorded"] for item in entries):
                print("  mouse-up unavailable in legacy log: down-to-action includes human press hold")
        elif kind == "corner_approach":
            configured = [item["configured_reveal_delay_ms"] for item in entries
                          if item["configured_reveal_delay_ms"] is not None]
            dwell = [item["stages"]["hotspot_to_reveal_decision"] for item in entries
                     if "hotspot_to_reveal_decision" in item["stages"]]
            if configured and dwell:
                print(f"  configured_dwell_ms={statistics.median(configured):.0f} "
                      f"hotspot_to_decision_median_ms={statistics.median(dwell):.2f}")
            for key in ("approach_to_hotspot_sample", "hotspot_sample_to_followup_due",
                        "hotspot_sample_to_reveal_decision"):
                measured = [item["stages"][key] for item in entries if key in item["stages"]]
                if measured:
                    print(f"  {key}: median={statistics.median(measured):.2f}ms "
                          f"worst={max(measured):.2f}ms n={len(measured)}")
    stalls = [item for item in touches if (item["total"] if item["total"] is not None
                                             else item["observed_ms"] or 0) > 500]
    print(f"\nStalls >500ms to candidate or last recorded stage: {len(stalls)}")
    for item in stalls:
        print(f"run={item['run']} id={item['id']} kind={item['kind']} "
              f"first={item['first']} candidate_ms={item['total']} observed_ms={item['observed_ms']} "
              f"idle_ms={item['idle_ms']} "
              f"hidden_ms={item['hidden_ms']} released={item['released']} "
              f"nap_activity_requested={item['nap_activity']} app_nap_actual=unknown pageins={item['pageins']}")
        print("  stages_ms: " + ", ".join(f"{key}={value:.2f}" for key, value in sorted(item["stages"].items())))
        for i, memory in enumerate(item["memory"]):
            print(f"  memory_sample_{i}: footprint={memory['footprintBytes']} "
                  f"resident={memory['residentBytes']} compressed={memory['compressedBytes']} "
                  f"valid={memory['valid']}")
    print("Notes: overlapping spans are not additive; resident and compressed are not subtracted from footprint.")
    print("Mouse-up -> action return bounds synchronous event delivery, not an async action's completion.")
    print("CA commit and WindowServer/render-server time are unmeasured by this in-process log.")


def report_controls(touches):
    """Action dispatch is separate from the end of synchronous event delivery."""
    valid = KNOWN_CONTROLS
    entries = collections.defaultdict(list)
    for touch in touches:
        if touch["kind"] not in ("panel_control", "island_action", "keyboard_control"):
            continue
        key = touch["control"] or "unclassified_panel"
        entries[key].append(touch)
    print("\nControl stages (ms; n=measured; p90 is observed, not extrapolated):")
    for key in (*valid, "unclassified_panel"):
        group = entries[key]
        print(f"  {key}: touches={len(group)} mouse_up={sum(t['mouse_up_recorded'] for t in group)}")
        phases = ("key_to_action_dispatch", "mouse_up_to_action_dispatch",
                  "mouse_up_to_action_return", "action_dispatch_to_handoff",
                  "view_to_commit_handoff", "handoff_to_frame_candidate",
                  "mouse_up_to_frame_candidate")
        discovered = sorted({name for t in group for name in t["stages"] if name.startswith("span:")})
        counters = sorted({name for t in group for name in t["counts"]})
        for phase in (*phases, *discovered, *(f"count:{name}" for name in counters)):
            values = sorted(t["counts"][phase[6:]] if phase.startswith("count:")
                            else t["stages"][phase]
                            for t in group if (phase[6:] in t["counts"] if phase.startswith("count:")
                                               else phase in t["stages"]))
            if values:
                print(f"    {phase}: n={len(values)} median={statistics.median(values):.2f} "
                      f"p90={values[math.ceil(len(values) * .9) - 1]:.2f} "
                      f"worst={values[-1]:.2f} >100ms={sum(v > 100 for v in values)}")
        if key == "unclassified_panel":
            pages = collections.Counter(t["page"] for t in group)
            print("    pages: " + ", ".join(f"{page}={count}" for page, count in sorted(pages.items())))
    if entries["unclassified_panel"]:
        print("  Original panel-control records have no button identity: unlabeled events "
              "cannot be retroactively assigned to a button.")


GRAPHICS_GUIDE = """Render-server investigation on the owner's Pro (only when wanted; not always-on):
  xcrun xctrace record --template 'Metal System Trace' --all-processes --time-limit 45s --output first-touch-gpu.trace
  xcrun xctrace record --template 'Animation Hitches' --all-processes --time-limit 45s --output first-touch-frames.trace
Open the traces in Instruments; inspect Attic and WindowServer GPU/CA work,
frame presentation, and App Nap separately (Energy Log / Activity Monitor).
Align their timestamps against the log's wallEpochMS (Unix milliseconds),
which is calculated from the monotonic input clock. The in-app display-link
candidate alone does NOT measure render-server time or displayed pixels.
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", nargs="?", type=Path, help="first-touch.jsonl in a preview's sandbox")
    parser.add_argument("--render-server-guide", action="store_true", help="system trace recipe for WindowServer timings")
    args = parser.parse_args()
    if args.render_server_guide:
        print(GRAPHICS_GUIDE)
    if args.log:
        if not args.log.is_file():
            parser.error(f"no log file: {args.log}")
        report([one_touch(group) for group in load(args.log)])
    elif not args.render_server_guide:
        parser.error("specify a log path or --render-server-guide")


if __name__ == "__main__":
    main()
