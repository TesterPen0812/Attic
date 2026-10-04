#!/usr/bin/env python3
"""Exercise OD-6 with real XCTest assertions and the production comparators.

The standalone XCTest executable opens no windows or app host. Synthetic
timings test failure plumbing, not performance; CI measures the real fixtures.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from prepare_cost_reference import ROOT, REPLACEMENTS, policy, prepare


def command(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, **kwargs)


class CostGatePlumbingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="AtticCostPlumbing-")
        cls.root = Path(cls.scratch.name)
        cls.probe = cls.root / "budget-probe"
        source = cls.root / "probe.swift"
        source.write_text('import Foundation\nimport XCTest\n' + policy() + r'''
final class BudgetProbe: XCTestCase {
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
let suite = BudgetProbe.defaultTestSuite
suite.run()
exit(suite.testRun!.executionCount == 1 && suite.testRun!.totalFailureCount == 0 ? 0 : 1)
''')
        developer = command(["xcode-select", "-p"], check=True).stdout.strip()
        frameworks = Path(developer) / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
        libraries = Path(developer) / "Platforms/MacOSX.platform/Developer/usr/lib"
        built = command(["xcrun", "swiftc", str(source), "-F", str(frameworks),
                         "-I", str(libraries), "-L", str(libraries),
                         "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                         "-Xlinker", "-rpath", "-Xlinker", str(libraries), "-o", str(cls.probe)])
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
        return command([str(self.probe)], env=env)

    def test_candidate_absolute_budgets_fail_and_reference_overages_pass(self):
        for bound, strict in [(16, False), (20.3, False), (77.15, False), (500, True)]:
            with self.subTest(bound=bound):
                self.assertEqual(self.budget(bound - 1, bound, "0", strict).returncode, 0)
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
            for i in (1, 2, 3):
                (root / f"candidate-cost-{i}.log").write_text((root / f"baseline-cost-{i}.log").read_text())
            self.assertEqual(command(script).returncode, 0)


if __name__ == "__main__":
    unittest.main()
