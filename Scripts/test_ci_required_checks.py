import contextlib
import io
from pathlib import Path
import tempfile
import unittest

from ci_required_checks import CHECKS, FULL_ONLY, PARALLEL_CHECKS, gate


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

    def test_fast_keeps_only_the_optional_checks_optional(self):
        self.assertEqual(FULL_ONLY, {'FKA_TESTS', 'PERF_UI_TESTS', 'DROPDOWN_TESTS'})
        env = dict.fromkeys(CHECKS, 'success')
        env.update(dict.fromkeys(FULL_ONLY, 'skipped'), LANE='fast')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate(env), 0)
            env['UNIT_TESTS'] = ''
            self.assertEqual(gate(env), 1)

    def test_dropdown_timing_reports_but_does_not_block_the_fast_lane(self):
        env = dict.fromkeys(CHECKS, 'success')
        env.update(DROPDOWN_TESTS='failure', LANE='fast')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate(env), 0)
            env['LANE'] = 'full'
            self.assertEqual(gate(env), 1)
            env['LANE'] = ''
            self.assertEqual(gate(env), 1)

    def test_success_and_pull_request_empty_lane(self):
        for lane in ['full', '']:
            env = dict.fromkeys(CHECKS, 'success')
            env['LANE'] = lane
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate(env), 0)
                env['FKA_TESTS'] = 'skipped'
                self.assertEqual(gate(env), 1)

    def test_both_parallel_lanes_are_required_in_fast_full_and_pull_requests(self):
        for lane in ['fast', 'full', '']:
            for key in PARALLEL_CHECKS:
                for outcome in ['failure', 'skipped', 'cancelled', '']:
                    with self.subTest(lane=lane, key=key, outcome=outcome):
                        env = dict.fromkeys(PARALLEL_CHECKS, 'success')
                        env['LANE'] = lane
                        with contextlib.redirect_stdout(io.StringIO()):
                            self.assertEqual(gate(env, PARALLEL_CHECKS), 0)
                            env[key] = outcome
                            self.assertEqual(gate(env, PARALLEL_CHECKS), 1)

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
        for job in ['fka', 'round-trips', 'macos', 'ui', 'costs', 'performance', 'appearance', 'iphone']:
            self.assertIn(f'  {job}:\n    needs: validate-inputs\n', workflow)

    def test_round_trips_are_a_required_parallel_job_without_reducing_coverage(self):
        root = Path(__file__).resolve().parent.parent
        workflow = (root / '.github/workflows/macos-ci.yml').read_text()
        job = workflow.split('  round-trips:', 1)[1].split('\n  macos:', 1)[0]
        self.assertIn('timeout-minutes: 35', job)
        self.assertNotIn('continue-on-error', job)
        self.assertNotIn('-skip-testing:', job)
        self.assertIn('-only-testing:AtticRoundTripTests', job)
        self.assertIn('s["passedTests"]==31+sum(map(len,routes.values()))', job)
        self.assertIn('s["skippedTests"]==0', job)
        self.assertIn('s["failedTests"]==0', job)
        self.assertNotIn('ATTIC_FX3_SEEDS:', job)
        generator = (root / 'Scripts/generate_project.rb').read_text()
        self.assertIn('scheme.add_test_target(round_trip_tests)', generator)
        self.assertIn('round_trip_scheme.add_test_target(round_trip_tests)', generator)
        self.assertIn('%w[RoundFX3Tests.swift TestSupport.swift InvisibleHostObserver.swift]', generator)
        required = workflow.split('  required:', 1)[1].split('\n  ui:', 1)[0]
        self.assertIn('needs: [validate-inputs, macos, round-trips]', required)
        self.assertIn("always() && inputs.lane != 'costs' && inputs.lane != 'fka'", required)
        self.assertIn('MACOS_JOB: ${{ needs.macos.result }}', required)
        self.assertIn('ROUND_TRIPS: ${{ needs.round-trips.result }}', required)
        self.assertIn('python3 Scripts/ci_required_checks.py --parallel', required)

    def test_generated_methods_compile_in_exactly_one_lane(self):
        import json
        import re
        root = Path(__file__).resolve().parent.parent
        routes = json.loads((root / 'Scripts/generated_test_routes.json').read_text())
        for filename, methods in routes.items():
            with self.subTest(filename=filename):
                source = (root / 'AtticTests' / filename).read_text()
                routed = []
                mode = None
                for line in source.splitlines():
                    if line.strip() in ['#if ATTIC_GENERATED_TESTS', '#if !ATTIC_GENERATED_TESTS']:
                        self.assertIsNone(mode)
                        mode = line.strip() == '#if ATTIC_GENERATED_TESTS'
                    elif line == '    #endif':
                        mode = None
                    elif match := re.match(r'    (?:@\w+ )*func (test\w+)\(', line):
                        self.assertIsNotNone(mode, f'Ungated test in shared source: {filename}:{match[1]}')
                        if mode:
                            routed.append(match[1])
                self.assertCountEqual(routed, methods)
        generator = (root / 'Scripts/generate_project.rb').read_text()
        self.assertIn("generated_routes.keys + ['RoundF3Harness.swift']", generator)
        self.assertIn("settings['OTHER_SWIFT_FLAGS'] += ' -DATTIC_GENERATED_TESTS'", generator)

    def test_focused_fka_includes_full_and_pull_request_scope(self):
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/macos-ci.yml').read_text()
        focused = workflow.split('  fka:', 1)[1].split('\n  macos:', 1)[0]
        self.assertIn("github.event_name != 'workflow_dispatch' || inputs.lane == 'fka' || inputs.lane == 'full'", focused)
        self.assertIn('Run Notes Undo before enabling Full Keyboard Access', focused)
        self.assertIn('run_tests unit 4', focused)
        self.assertIn('fka-task-focus-summary.json', focused)

    def test_optimized_cost_callers_keep_their_fixtures_in_the_main_bundle(self):
        import json
        import re
        root = Path(__file__).resolve().parent.parent
        routes = json.loads((root / 'Scripts/generated_test_routes.json').read_text())
        moved = {method for methods in routes.values() for method in methods}
        workflow = (root / '.github/workflows/macos-ci.yml').read_text()
        direct = set(re.findall(r'-only-testing:AtticTests/\w+/(test\w+)', workflow))
        rechecks = (root / 'Scripts/recheck_cost_gates.py').read_text()
        retry = set(re.findall(r"'\w+/(test\w+)'", rechecks))
        self.assertFalse(moved & (direct | retry),
                         'A moved method is still selected from AtticTests by a cost/FKA caller')


if __name__ == '__main__':
    unittest.main()
