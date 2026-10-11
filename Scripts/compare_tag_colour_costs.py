#!/usr/bin/env python3
"""CI-only paired colour1/base tag-picker measurements; functional gates stay intact."""
import argparse, json, os, re, statistics, subprocess
from pathlib import Path

REFS = {"base": "76e427656c8418ec0590390fc4215d6113a49c92", "colour": "4b25a1fab3217e177dcd0f70d7f0628d496493d3"}
LINE = re.compile(r"DROPDOWN_RATIO_AX (\w+) ratio=([\d.e+-]+).* new_ms=([\d.e+-]+) legacy_ms=([\d.e+-]+)")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--pairs", type=int, default=8)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    root = Path.cwd()
    builds = {}
    for side, ref in REFS.items():
        checkout = args.output / side
        subprocess.run(["git", "worktree", "add", "--detach", str(checkout), ref], check=True)
        dd = args.output / (side + "-dd")
        common = [str(root / "Scripts/xcodebuild_locked.sh"), "-project", str(checkout / "Attic.xcodeproj"), "-scheme", "Attic", "-configuration", "Local", "-destination", "platform=macOS", "-derivedDataPath", str(dd), "CODE_SIGNING_ALLOWED=NO"]
        with (args.output / (side + "-build.log")).open("w") as log:
            subprocess.run(common + ["build-for-testing"], cwd=checkout, stdout=log, stderr=subprocess.STDOUT, check=True)
        builds[side] = (checkout, common)
    records = []
    env = dict(os.environ, TEST_RUNNER_ATTIC_KEY_WINDOW_TESTS="1")
    for pair in range(args.pairs):
        order = ["base", "colour"] if pair % 2 == 0 else ["colour", "base"]
        for side in order:
            checkout, common = builds[side]
            log = args.output / f"pair-{pair+1:02}-{side}.log"
            with log.open("w") as stream:
                result = subprocess.run(common + ["test-without-building", "-parallel-testing-enabled", "NO", "-only-testing:AtticTests/AtticDropdownTests/testOpenAndFilterCostNoMoreThanBeforeWithAccessibilityOn"], cwd=checkout, env=env, stdout=stream, stderr=subprocess.STDOUT)
            text = log.read_text()
            measures = {m: {"ratio": float(r), "new_ms": float(n), "legacy_ms": float(l)} for m,r,n,l in LINE.findall(text)}
            # A historical gate may be red: preserve its exit and log, never call
            # that a pass. Incomplete/crashed measurements cannot be compared.
            assert set(measures) == {"slashOpen", "slashNarrow", "slashWiden", "tagOpen", "priorityOpen"}, log
            assert re.search(r"Executed 1 test, with \d+ failure", text), log
            records.append({"pair": pair+1, "side": side, "exit": result.returncode, "measures": measures})
            (args.output / "records.json").write_text(json.dumps(records, indent=2))
            print("TAG_COLOUR_PAIR", json.dumps(records[-1]), flush=True)
    ratios = []
    for pair in range(1,args.pairs+1):
        sample = {r["side"]:r["measures"]["tagOpen"] for r in records if r["pair"] == pair}
        ratios.append(sample["colour"]["new_ms"] / sample["base"]["new_ms"])
    summary = {"pairs": args.pairs, "colour_over_base_tag_ms": ratios, "median": statistics.median(ratios), "records": records}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2))
    print("TAG_COLOUR_COMPARISON", json.dumps({k:v for k,v in summary.items() if k != "records"}), flush=True)

if __name__ == "__main__":
    main()
