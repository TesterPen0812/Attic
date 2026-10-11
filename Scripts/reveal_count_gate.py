#!/usr/bin/env python3
"""Reject multiplied cold-reveal work against an identically instrumented reference.

Compares native view/layer counts, Objective-C callbacks, and separately
resolved Swift-only environment/appearance and C++ CA commit counters.
"""
import argparse
import json
from pathlib import Path

SETTINGS = ("mode", "frame_monitor", "settle_seconds", "idle_sample_seconds", "allocations", "reveal_counts")


def metrics(document):
    if document.get("bundle") != "com.taha.Attic.preview.phasex":
        raise ValueError("Expected the isolated phasex identity")
    if document.get("settings", {}).get("reveal_counts") is not True:
        raise ValueError("Expected count-instrumented evidence")
    counts = document["counts"]
    if not counts.get("hooks"):
        raise ValueError("Missing observable callback hooks")
    native = counts.get("native_function_counts")
    required = ("hosting_environment_updates", "native_appearance_applications", "ca_transaction_commits")
    if not native or any(name not in native or type(native[name].get("locations")) is not int
                         or native[name]["locations"] < 1 for name in required):
        raise ValueError("Missing or unresolved native function counters")
    hierarchy = counts["after"]
    result = {name: hierarchy[name] for name in
              ("hosting_roots", "views", "key_loop_views", "layer_backed_views")}
    result.update({name: native[name]["calls"] for name in required})
    calls = counts["ordering_calls"]
    for label, match in (
        ("appearance_callbacks", lambda key: key.endswith(".viewDidChangeEffectiveAppearance")),
        ("global_environment_callbacks", lambda key: key.endswith(".globalEnvironmentDidChange")),
        ("appearance_drawing_scopes", lambda key: key == "NSAppearance.performAsCurrentDrawingAppearance"),
        ("explicit_ca_commits", lambda key: key == "CATransaction.commit"),
        ("tasks_body_evaluations", lambda key: key == "TasksPage.body"),
        ("field_updates", lambda key: key == "AtticTokenField.updateNSView"),
    ):
        result[label] = sum(value for key, value in calls.items() if match(key))
    if any(type(value) is not int or value < 0 for value in result.values()):
        raise ValueError("Counts must be non-negative integers")
    if result["hosting_roots"] < 1:
        raise ValueError("Missing the panel hosting root")
    return result


def compare(reference, candidate):
    settings = [{key: doc.get("settings", {}).get(key) for key in SETTINGS}
                for doc in (reference, candidate)]
    if settings[0] != settings[1]:
        raise ValueError("Count comparisons require identical settings")
    if reference["counts"]["hooks"] != candidate["counts"]["hooks"]:
        raise ValueError("Count comparisons require identical observable hooks")
    states = [tuple(doc["counts"]["after"].get(key) for key in ("panel_is_key", "app_key_is_panel"))
              for doc in (reference, candidate)]
    if any(type(value) is not bool for state in states for value in state) or states[0] != states[1]:
        raise ValueError("Native key-window states must be recorded and identical")
    before, after = metrics(reference), metrics(candidate)
    a, b = reference["counts"]["native_function_counts"], candidate["counts"]["native_function_counts"]
    if {name: row["locations"] for name, row in a.items()} != {name: row["locations"] for name, row in b.items()}:
        raise ValueError("Native function breakpoint coverage differs")
    regressions = {key: {"reference": value, "candidate": after[key]}
                   for key, value in before.items() if after[key] > value}
    return dict(reference=before, candidate=after, regressions=regressions, passed=not regressions)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    result = compare(json.loads(args.reference.read_text()), json.loads(args.candidate.read_text()))
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["passed"] else 1)
