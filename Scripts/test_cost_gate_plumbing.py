#!/usr/bin/env python3
"""Exercise OD-6 with real XCTest assertions and the production comparators.

The standalone XCTest bundle opens no windows or app host. Synthetic
timings test failure plumbing, not performance; CI measures the real fixtures.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

from prepare_cost_reference import ROOT, REPLACEMENTS, policy, prepare
from check_integration_costs import METRICS


def command(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, **kwargs)


class CostGatePlumbingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="AtticCostPlumbing-")
        cls.root = Path(cls.scratch.name)
        cls.probe = cls.root / "BudgetProbe.xctest"
        executable = cls.probe / "Contents/MacOS/BudgetProbe"
        executable.parent.mkdir(parents=True)
        with (cls.probe / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(dict(CFBundleExecutable="BudgetProbe", CFBundleIdentifier="com.taha.Attic.cost-plumbing",
                              CFBundlePackageType="BNDL"), stream)
        source = cls.root / "probe.swift"
        source.write_text('import Foundation\nimport XCTest\n' + policy() + r'''
@objc(BudgetProbe) final class BudgetProbe: XCTestCase {
    func testBudget() {
        let env = ProcessInfo.processInfo.environment
        let measured = Double(env["PROBE_MEASURED"]!)!
        let bound = Double(env["PROBE_BOUND"]!)!
        if env["PROBE_STRICT"] == "1" {
            CostBudget.assertLessThan(measured, bound, "injected budget")
        } else {
            CostBudget.assertLessThanOrEqual(measured, bound, "injected budget")
        }
        // OD-6 must never bypass functional correctness assertions.
        XCTAssertEqual(env["PROBE_CORRECT"], "1")
    }
}
''')
        platform = Path(command(["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], check=True).stdout.strip())
        sdk = command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], check=True).stdout.strip()
        frameworks = platform / "Developer/Library/Frameworks"
        libraries = platform / "Developer/usr/lib"
        built = command(["xcrun", "swiftc", "-sdk", sdk, "-emit-library", str(source), "-F", str(frameworks),
                         "-I", str(libraries), "-L", str(libraries),
                         "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                         "-Xlinker", "-rpath", "-Xlinker", str(libraries), "-o", str(executable)])
        if built.returncode:
            raise RuntimeError(built.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def budget(self, measured, bound, reference=None, strict=False, correct=True):
        env = dict(os.environ)
        env.pop("ATTIC_COST_REFERENCE_ONLY", None)
        if reference is not None:
            env["ATTIC_COST_REFERENCE_ONLY"] = reference
        env.update(PROBE_MEASURED=str(measured), PROBE_BOUND=str(bound),
                   PROBE_STRICT=str(int(strict)), PROBE_CORRECT=str(int(correct)))
        result = command(["xcrun", "xctest", str(self.probe)], env=env)
        self.assertIn("Executed 1 test", result.stdout + result.stderr,
                      "Probe did not execute: " + result.stdout + result.stderr)
        self.assertIn(result.returncode, (0, 1), result.stdout + result.stderr)
        return result

    def test_candidate_absolute_budgets_fail_and_reference_overages_pass(self):
        for bound, strict in [(16, False), (500, True), (2, True)]:
            with self.subTest(bound=bound):
                passed = self.budget(bound - 1, bound, "0", strict)
                self.assertEqual(passed.returncode, 0, passed.stdout + passed.stderr)
                self.assertNotEqual(self.budget(bound + 1, bound, "0", strict).returncode, 0)
                reference = self.budget(bound + 1, bound, "1", strict)
                self.assertEqual(reference.returncode, 0, reference.stdout + reference.stderr)
                self.assertIn("assertion=disabled", reference.stdout)

    def test_enforcement_is_default_and_only_exact_one_disables_it(self):
        for flag in [None, "0", "true", ""]:
            self.assertNotEqual(self.budget(17, 16, flag).returncode, 0)
        self.assertEqual(self.budget(16, 16, "0").returncode, 0)
        self.assertNotEqual(self.budget(500, 500, "0", strict=True).returncode, 0)

    def test_reference_correctness_failure_still_fails(self):
        self.assertNotEqual(self.budget(17, 16, "1", correct=False).returncode, 0)

    def test_historical_adapters_change_only_selected_absolute_assertions(self):
        for commit, fixture in [("3eee023", "frame-row"), ("dab5d2f", "done")]:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "AtticTests").mkdir()
                originals = {}
                names = ["TasksFrameCostTests.swift", "TasksRowBuildCostTests.swift"]
                if fixture == "done":
                    names.append("DoneSearchCostTests.swift")
                for name in names:
                    originals[name] = command(["git", "show", f"{commit}:AtticTests/{name}"],
                                               cwd=ROOT, check=True).stdout
                    (root / "AtticTests" / name).write_text(originals[name])
                prepare(root, fixture)
                changed = ["TasksFrameCostTests.swift"] + (["DoneSearchCostTests.swift"] if fixture == "done" else [])
                for name, original in originals.items():
                    expected = original
                    if name in changed:
                        for old, new in REPLACEMENTS[name]:
                            expected = expected.replace(old, new)
                        if name == "TasksFrameCostTests.swift":
                            expected += "\n" + policy()
                    self.assertEqual((root / "AtticTests" / name).read_text(), expected)

    def test_adapter_fails_closed_on_unexpected_historical_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "AtticTests").mkdir()
            path = root / "AtticTests/TasksFrameCostTests.swift"
            path.write_text("unknown fixture")
            with self.assertRaises(ValueError):
                prepare(root, "frame-row")
            self.assertEqual(path.read_text(), "unknown fixture")

    def done_logs(self, directory, baseline=18, candidate=10):
        memory = lambda session, value: f"ATTIC_DONE_SEARCH session={session} query=F page/group/count_ms=[] total_ms={value}\n"
        disk = lambda session, value: f"ATTIC_PHASE5_DONE {session}query=F legacy_page_count_lower_bound_ms=1 indexed_page_group_count_ms={value}\n"
        for i in (1, 2, 3):
            (directory / f"done-search-baseline-{i}.log").write_text(
                "".join(memory(s, baseline) for s in range(3)) + disk("", baseline))
        (directory / "done-search.log").write_text(
            "".join(memory(s, candidate) + disk(f"session={s} ", candidate) for s in range(3)))

    def test_done_regression_fails_even_when_candidate_fits_absolute_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.done_logs(root, baseline=10, candidate=11)
            self.assertEqual(self.budget(11, 16, "0").returncode, 0)
            result = command(["python3", str(ROOT / "Scripts/check_done_search_costs.py"), str(root)])
            self.assertNotEqual(result.returncode, 0)
            report = json.loads((root / "done-search-comparison.json").read_text())
            self.assertEqual(set(report), {"memory", "phase5"})
            self.assertTrue(all(not row["passed"] for row in report.values()))

    def test_only_baseline_over_budget_passes_complete_gate_chain(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.done_logs(root)
            self.assertEqual(self.budget(18, 16, "1").returncode, 0)
            self.assertEqual(self.budget(10, 16, "0").returncode, 0)
            result = command(["python3", str(ROOT / "Scripts/check_done_search_costs.py"), str(root)])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads((root / "done-search-comparison.json").read_text())
            self.assertTrue(all(row["passed"] for row in report.values()))

    def test_done_quantum_metadata_allows_one_step_but_blocks_two(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            script = ["python3", str(ROOT / "Scripts/check_done_search_costs.py"), str(root)]
            for candidate, expected in [(11, 0), (12, 1)]:
                self.done_logs(root, baseline=10, candidate=candidate)
                with (root / "done-search.log").open("a") as log:
                    for fixture in ("memory", "phase5"):
                        log.write(f"ATTIC_COST_QUANTUM metric={fixture}:F quantum_ms=1\n")
                self.assertEqual(command(script).returncode, expected)
                report = json.loads((root / "done-search-comparison.json").read_text())
                for row in report.values():
                    self.assertEqual(row['queries']['F']['resolution_ms'], 1)
                    self.assertEqual(row['queries']['F']['bound_ms'], 11.2)

    def test_notes_save_comparator_exit_status_keeps_every_notes_row_blocking(self):
        notes = {name for name in METRICS if name.startswith('note-')}
        rendered = ''.join(f'ATTIC_DONE_RESULTS run={i} frame_ms=40\n' for i in range(3)) + ''.join(
            f'ATTIC_DONE_KEY key={i} raw_ms=[40, 40, 40]\n' for i in range(len('Finished task 12')))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for candidate, expected in [(81, 0), (82, 1)]:
                for side in ('baseline', 'candidate'):
                    for sample in (1, 2, 3):
                        log = ''.join(f'ATTIC_INTEGRATION_COST {name} median_ms={candidate if side == "candidate" and name in notes else 80}\n'
                                      for name in METRICS)
                        log += 'NOTE_RECOVERY_CONTROL_MAIN_ACTOR_MS_MEDIAN=0\n'
                        if side == 'baseline':
                            log += ''.join(f'ATTIC_COST_SAMPLES metric={name} raw_ms=[80, 81]\n' for name in notes)
                            if sample == 1:
                                log += rendered
                        (root / f'integration-{side}-{sample}.log').write_text(log)
                (root / 'done-search.log').write_text(rendered)
                result = command(['python3', str(ROOT / 'Scripts/check_integration_costs.py'), str(root)])
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                report = json.loads((root / 'integration-cost-comparison.json').read_text())
                for name in notes:
                    self.assertEqual(report[name]['bound_ms'], 81.2)
                    self.assertEqual(report[name]['passed'], expected == 0)

    def test_frame_row_comparator_fails_candidate_regression_and_prints_every_metric(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, value in [("baseline", 10), ("candidate", 11)]:
                frame = "ATTIC_FRAME_COST feel=Lively | " + " | ".join(
                    f"{metric} n=3 median={value}ms max={value}ms" for metric in
                    ["select-1-page", "select-3-pages", "swipe-follow-frames", "swipe-settle-frames",
                     "keystroke", "title-keystroke", "search-keystroke"])
                frame += f" | click-first now={value}ms backlog={value}ms done={value}ms\n"
                row = f"ATTIC_ROW_BUILD empty=0ms rows=+{value}ms lazy-scroll=+{value}ms\n"
                for i in (1, 2, 3):
                    (root / f"{name}-cost-{i}.log").write_text(frame + row)
            script = ["python3", str(ROOT / "Scripts/check_cost_comparison.py"), str(root)]
            result = command(script)
            self.assertNotEqual(result.returncode, 0)
            report = json.loads((root / "cost-comparison.json").read_text())
            self.assertEqual(len(report), 12)
            self.assertTrue(all(not row["passed"] for row in report.values()))
            # The documented quantum of this synthetic fixture is 1 ms.
            quantum = ''.join(f'ATTIC_COST_QUANTUM metric={metric} quantum_ms=1\n' for metric in report)
            path = root / 'candidate-cost-1.log'
            path.write_text(path.read_text() + quantum)
            self.assertEqual(command(script).returncode, 0)
            for i in (1, 2, 3):
                path = root / f'candidate-cost-{i}.log'
                path.write_text(path.read_text().replace('=11ms', '=12ms').replace('+11ms', '+12ms'))
            self.assertNotEqual(command(script).returncode, 0)
            for i in (1, 2, 3):
                (root / f"candidate-cost-{i}.log").write_text((root / f"baseline-cost-{i}.log").read_text())
            self.assertEqual(command(script).returncode, 0)


if __name__ == "__main__":
    unittest.main()
