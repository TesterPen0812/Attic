#!/usr/bin/env python3
"""Summarize a Local preview's bounded Attic/Diagnostics/first-touch.jsonl.

Per-touch monotonic stages are best-effort. A CADisplayLink callback is a frame
candidate, not proven scan-out, and CA/WindowServer times require a system trace.
"""
import argparse
import collections
import json
import statistics
from pathlib import Path


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
    stages = {r.get("stage"): r["atNS"] for r in records if r["event"] == "stage"}
    spans = {r["stage"]: ms_between(r.get("spanStartNS"), r["atNS"])
             for r in records if r["event"] == "span"}
    frames = [r["atNS"] for r in records if r["event"] == "frame_candidate"]
    candidate = frames[0] if frames else None
    input_ns = first["atNS"]
    origin = first.get("originNS", input_ns)
    parts = {}
    boundaries = [
        ("event_delivery", origin, input_ns),
        ("callback_to_handler", input_ns, stages.get("handler_entered") or stages.get("reveal_decision")),
        ("handler_to_reveal_decision", stages.get("handler_entered"), stages.get("reveal_decision")),
        ("reveal_to_view_dispatch", stages.get("reveal_decision"), stages.get("view_dispatch_done")),
        ("handler_to_down_return", stages.get("handler_entered"), stages.get("mouse_down_returned")),
        ("down_to_view_dispatch", stages.get("mouse_down_returned"), stages.get("view_dispatch_done")),
        ("view_to_commit_handoff", stages.get("view_dispatch_done"), stages.get("commit_handoff") or stages.get("transaction_flushed")),
        ("view_to_transaction_flush", stages.get("view_dispatch_done"), stages.get("transaction_flushed")),
        ("handoff_to_frame_candidate", stages.get("commit_handoff") or stages.get("transaction_flushed"), candidate),
    ]
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
    observed = [r["atNS"] for r in records if r["event"] in ("stage", "span", "frame_candidate")]
    observed_ms = ms_between(origin, max(observed)) if observed else None
    memory = [r for r in records if r["event"] == "memory" and r.get("memory")]
    memory.sort(key=lambda r: r["atNS"])
    pageins = None
    if len(memory) > 1 and (memory[0]["memory"]["valid"] & memory[-1]["memory"]["valid"] & 2):
        pageins = max(0, memory[-1]["memory"]["pageins"] - memory[0]["memory"]["pageins"])
    return {
        "kind": first.get("kind", "unknown"),
        "first": bool(first.get("firstAfterIdle")),
        "idle_ms": first.get("idleMS"),
        "hidden_ms": first.get("hiddenMS"),
        "total": ms_between(origin, candidate),
        "observed_ms": observed_ms,
        "stages": parts,
        "released": first.get("released"),
        "nap_activity": first.get("napActivity"),
        "pageins": pageins,
        "memory": [r["memory"] for r in memory],
        "id": first["id"],
        "run": first.get("run", "legacy"),
    }


def report(touches):
    print(f"Touches: {len(touches)} (frame = next display-link callback; presentation/scan-out unverified)")
    cohorts = collections.defaultdict(list)
    for item in touches:
        cohorts[(item["kind"], "first" if item["first"] else "repeat")].append(item)
    for (kind, label), entries in sorted(cohorts.items()):
        totals = [item["total"] for item in entries if item["total"] is not None]
        biggest = max(((value, key) for item in entries for key, value in item["stages"].items()), default=(0, "unmeasured"))
        median = f"{statistics.median(totals):.2f}" if totals else "no candidate"
        print(f"{kind:18s} {label:6s} n={len(entries)} candidate_median_ms={median} "
              f"slowest_observed_stage={biggest[1]}:{biggest[0]:.2f}ms missing_frame={len(entries)-len(totals)}")
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
    print("CA commit and WindowServer/render-server time are unmeasured by this in-process log.")


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
