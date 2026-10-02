#!/usr/bin/env python3
"""Compare d77ec80 and afebc3a with identical save/scaling test fixtures.

Diagnostics retain every assertion and raw xcresult, including failed baseline
runs. They do not replace the required full unit-test lane or change its gates.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess

BASELINE = "d77ec80ad91930d377bb3a5849c030c4d63c541e"
CANDIDATE = "afebc3a9a8d721f3fb3296e39d298d5ae0256456"
TEST_FILE = "AtticTests/NotesPageControllerTests.swift"
TESTS = [
    "AtticTests/NotesPageControllerTests/testMeasuredMainActorSaveOnFiveThousandLineNote",
    "AtticTests/NotesPageControllerTests/testMeasuredMainActorSaveIsIndependentOfUnrelatedStoreContents",
]


def run_logged(command, cwd, path):
    with path.open("w") as log:
        return subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--xcodebuild-wrapper", type=Path,
                        help="Local runs use the required external locked wrapper; CI uses the same lock directly")
    parser.add_argument("--unsigned", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    # Port only the identical measurement fixture; baseline production code
    # remains at d77ec80. Remove one unselected test requiring the new decoder
    # injection API so both test files compile with the old initializer.
    fixture = subprocess.check_output(["git", "show", f"{CANDIDATE}:{TEST_FILE}"], cwd=root, text=True)
    start = fixture.index("    func testRecoveryRetirementKeepsCheckpointOnFailedOrStaleDecode()")
    end = fixture.index("    // Local configuration, macos-26", start)
    fixture = fixture[:start] + fixture[end:]
    wrapper = ([str(args.xcodebuild_wrapper.resolve())] if args.xcodebuild_wrapper else
               ["/usr/bin/lockf", "-k", "/tmp/attic-xcodebuild.lock", "/usr/bin/xcodebuild"])
    signing = (["CODE_SIGNING_ALLOWED=NO"] if args.unsigned else
               ["CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM="])
    specs = {}
    results = []
    try:
        for side, commit in [("baseline", BASELINE), ("candidate", CANDIDATE)]:
            tree = output / side
            subprocess.run(["git", "worktree", "add", "--detach", str(tree), commit], cwd=root, check=True)
            specs[side] = tree
            (tree / TEST_FILE).write_text(fixture)
            # No production inputs may differ from the stated commit.
            subprocess.run(["git", "diff", "--exit-code", "--", "Attic", "Attic.xcodeproj"], cwd=tree, check=True)
            command = wrapper + ["-project", "Attic.xcodeproj", "-scheme", "Attic", "-configuration", "Local",
                                 "-destination", "platform=macOS", "-derivedDataPath", str(output / f"dd-{side}")]
            command += signing + [f"-only-testing:{test}" for test in TESTS]
            specs[side] = (tree, command)
            if run_logged(command + ["build-for-testing"], tree, output / f"{side}-build.log"):
                raise RuntimeError(f"{side} test build failed; inspect its log")
        # Warm both executables once. Four measured runs per commit are
        # independent test-host invocations on this single runner, balanced AB/BA.
        for pair in range(-1, 4):
            for side in (["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]):
                tree, command = specs[side]
                prefix = output / f"{side}-{pair}"
                bundle = Path(str(prefix) + ".xcresult")
                code = run_logged(command + ["-resultBundlePath", str(bundle), "test-without-building"],
                                  tree, prefix.with_suffix(".log"))
                summary = json.loads(subprocess.check_output([
                    "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle), "--format", "json",
                ]))
                text = prefix.with_suffix(".log").read_text()
                metrics = {key: float(value) for key, value in re.findall(r"(NOTE_[A-Z0-9_]+)=(-?[0-9.]+)", text)}
                for label, prepared in re.findall(
                        r"(NOTE_[A-Z_]+)_SAVE_MS_MEDIAN=[0-9.]+ PREPARED_MS_MEDIAN=([0-9.]+)", text):
                    metrics[label + "_PREPARED_MS_MEDIAN"] = float(prepared)
                record = dict(pair=pair, side=side, commit=BASELINE if side == "baseline" else CANDIDATE,
                              test_exit=code, summary=summary, metrics=metrics)
                results.append(record)
                (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
                print(json.dumps({key: record[key] for key in ["pair", "side", "test_exit", "metrics"]}), flush=True)
                if summary["totalTestCount"] != len(TESTS) or code not in (0, 65):
                    raise RuntimeError("Unexpected test execution; inspect raw log and xcresult")
                if not all(key in metrics for key in ["NOTE_SAVE_5000_LINES_MS_MEDIAN",
                                                      "NOTE_POPULATED_ATTACHMENT_PREPARED_MS_MEDIAN"]):
                    raise RuntimeError("Missing gate measurements")
    finally:
        for spec in specs.values():
            tree = spec[0] if isinstance(spec, tuple) else spec
            # These are this script's disposable detached trees, with only
            # its test-fixture overlay. Keep build/results evidence outside them.
            subprocess.run(["git", "worktree", "remove", "--force", str(tree)], cwd=root, check=True)


if __name__ == "__main__":
    main()
