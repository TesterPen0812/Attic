import contextlib
import io
from pathlib import Path
import tempfile
import unittest

from ci_required_checks import CHECKS, FULL_ONLY, gate


class RequiredChecksTests(unittest.TestCase):
    def run_gate(self, **changes):
        env = dict.fromkeys(CHECKS, 'success')
        env['LANE'] = 'full'
        env.update(changes)
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / 'summary.md'
            env['GITHUB_STEP_SUMMARY'] = str(summary)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = gate(env)
            return status, output.getvalue(), summary.read_text()

    def test_every_failed_check_is_named_and_missing_is_failure(self):
        for outcome in ['failure', 'skipped', 'cancelled', 'canceled', '']:
            with self.subTest(outcome=outcome):
                status, output, summary = self.run_gate(**dict.fromkeys(CHECKS, outcome))
                self.assertEqual(status, 1)
                self.assertEqual(output.count('::error '), len(CHECKS))
                for name in CHECKS.values():
                    self.assertIn(f'::{name}: ', output)
                    self.assertIn(name, summary)

    def test_fast_keeps_only_the_existing_two_optional_checks_optional(self):
        env = dict.fromkeys(CHECKS, 'success')
        env.update(dict.fromkeys(FULL_ONLY, 'skipped'), LANE='fast')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate(env), 0)
            env['UNIT_TESTS'] = ''
            self.assertEqual(gate(env), 1)

    def test_success_and_pull_request_empty_lane(self):
        for lane in ['full', '']:
            env = dict.fromkeys(CHECKS, 'success')
            env['LANE'] = lane
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate(env), 0)
                env['FKA_TESTS'] = 'skipped'
                self.assertEqual(gate(env), 1)

    def test_workflow_passes_actual_step_outcomes(self):
        import re
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/macos-ci.yml').read_text()
        gate_step = workflow.split('name: Require established macOS verifications', 1)[1].split('\n  ui:', 1)[0]
        actual = dict(re.findall(r'([A-Z_]+): \$\{\{ steps\.([a-z_]+)\.outcome \}\}', gate_step))
        self.assertEqual(actual, dict(PROJECT_VERIFY='project_verify', MAC_BUILD='mac_build',
            STRICT_BUILD='strict_build', UNIT_TESTS='unit_tests', DROPDOWN_TESTS='dropdown_tests',
            FKA_TESTS='fka_tests', PERF_UI_TESTS='perf_ui_tests', ANALYZER='analyzer', FINAL_STATE='final_state'))
        for step in actual.values():
            self.assertIn(f'id: {step}\n', workflow)

    def test_headless_inputs_are_rejected_outside_the_costs_lane(self):
        import os
        import subprocess
        import textwrap
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/macos-ci.yml').read_text()
        validation = workflow.split('  validate-inputs:', 1)[1].split('\n  fka:', 1)[0]
        script = textwrap.dedent(validation.split('        run: |\n', 1)[1])
        for lane in ['', 'full', 'fast', 'costs', 'fka']:
            for headless in ['true', 'false', '']:
                with self.subTest(lane=lane, headless=headless):
                    result = subprocess.run(['/bin/bash', '-e', '-c', script],
                        env=dict(os.environ, LANE=lane, HEADLESS_COSTS=headless), capture_output=True, text=True)
                    self.assertEqual(result.returncode, int(headless == 'true' and lane != 'costs'))
                    if result.returncode: self.assertIn('::error::headless_costs=true requires lane=costs', result.stdout)
        for job in ['fka', 'macos', 'ui', 'costs', 'performance', 'appearance', 'iphone']:
            self.assertIn(f'  {job}:\n    needs: validate-inputs\n', workflow)

    def test_focused_fka_includes_full_and_pull_request_scope(self):
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/macos-ci.yml').read_text()
        focused = workflow.split('  fka:', 1)[1].split('\n  macos:', 1)[0]
        self.assertIn("github.event_name != 'workflow_dispatch' || inputs.lane == 'fka' || inputs.lane == 'full'", focused)
        self.assertIn('Run Notes Undo before enabling Full Keyboard Access', focused)
        self.assertIn('run_tests unit 4', focused)
        self.assertIn('fka-task-focus-summary.json', focused)


if __name__ == '__main__':
    unittest.main()
