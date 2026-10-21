"""Keep expensive retention gates opt-in locally and mandatory in full CI."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
SOAK_TESTS = (
    'testPerf2SimulatedHourRetainsOnlyTheWarmNoteSessions',
    'testPerf2TableMeasurementRetentionOverAnHourOfEdits',
    'testPerf2TableCacheKeepsAMaximumTableWarmAndRemeasuresEvictedText',
)

class SoakTestPlumbingTests(unittest.TestCase):
    def test_each_heavy_gate_checks_opt_in_before_allocating(self):
        source = (ROOT / 'AtticTests/NoteEditorEngineTests.swift').read_text()
        for name in SOAK_TESTS:
            with self.subTest(test=name):
                body = re.search(r'func ' + name + r'\([^)]*\)[^{]*\{\s*([^\n]+)', source)
                self.assertIsNotNone(body)
                self.assertEqual(body.group(1).strip(), 'try requireSoakTests()')
        self.assertIn('environment["ATTIC_SOAK_TESTS"] == "1"', source)
        self.assertIn('throw XCTSkip(', source)

    def test_costs_lane_runs_and_requires_all_heavy_gates(self):
        workflow = (ROOT / '.github/workflows/macos-ci.yml').read_text()
        costs = workflow.split('\n  costs:', 1)[1].split('\n  performance:', 1)[0]
        self.assertIn("inputs.lane != 'fast' && inputs.lane != 'fka'", costs)
        step = costs.split('- name: Run opt-in soak and retention gates', 1)[1].split('\n      - name:', 1)[0]
        self.assertIn('TEST_RUNNER_ATTIC_SOAK_TESTS: "1"', step)
        self.assertIn('-parallel-testing-enabled NO', step)
        self.assertNotIn('continue-on-error: true', step)
        for name in SOAK_TESTS:
            self.assertIn('-only-testing:AtticTests/NoteEditorEngineTests/' + name, step)
        self.assertIn('s["passedTests"] == 3', step)
        self.assertIn('s["skippedTests"] == 0', step)
        self.assertIn('s["failedTests"] == 0', step)

if __name__ == '__main__':
    unittest.main()
