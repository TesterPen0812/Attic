#!/usr/bin/env python3
"""Record five paired reference/candidate preview runs in alternating order.

Run this on one macOS runner. The preview owns and removes each unique sandbox;
the machine-wide lock covers every individual measurement. Exit status from
comparison remains observational in CI until runner stability is established.
"""

import argparse
import json
from pathlib import Path
import secrets
import subprocess
import sys


LOCK = "/tmp/attic-xcodebuild.lock"


def command(*argv):
    subprocess.run(argv, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("output_prefix", type=Path)
    parser.add_argument("--pairs", type=int, default=5)
    parser.add_argument("--window", type=int, default=10)
    args = parser.parse_args()
    if args.pairs < 5 or not 0 < args.window <= 12:
        parser.error("At least five pairs and a window in (0, 12] are required")

    specs = {}
    for side, tree in (("reference", args.reference), ("candidate", args.candidate)):
        script = tree.resolve() / "Scripts" / "performance_probe.py"
        identity = secrets.token_hex(5)
        command(sys.executable, str(script), "--build-only", "--identity", identity)
        specs[side] = (script, identity)

    accumulated = {}
    args.output_prefix.parent.mkdir(parents=True, exist_ok=True)
    for pair in range(1, args.pairs + 1):
        # AB, BA, AB... balances warm-up and runner drift.
        order = ("reference", "candidate") if pair % 2 else ("candidate", "reference")
        for side in order:
            script, identity = specs[side]
            temporary = args.output_prefix.with_name(f"{args.output_prefix.name}-{side}-{pair}.json")
            command("/usr/bin/lockf", "-k", LOCK, sys.executable, str(script),
                    "--measure", "--identity", identity, "--runs", "1",
                    "--window", str(args.window), "--output", str(temporary))
            sample = json.loads(temporary.read_text())
            run = sample["runs"][0]
            if side not in accumulated:
                accumulated[side] = sample
                accumulated[side]["runs"] = []
            run["run"] = pair
            accumulated[side]["runs"].append(run)
            temporary.unlink()
            temporary.with_suffix(".md").unlink(missing_ok=True)

    for side, document in accumulated.items():
        destination = args.output_prefix.with_name(f"{args.output_prefix.name}-{side}.json")
        destination.write_text(json.dumps(document, indent=2) + "\n")
        print(destination)


if __name__ == "__main__":
    main()
