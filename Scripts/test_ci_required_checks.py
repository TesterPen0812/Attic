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

    def test_all_parallel_lanes_are_required_in_fast_full_and_pull_requests(self):
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

    def test_explicit_performance_ui_selection_is_not_silently_skipped(self):
        import os
        import subprocess
        import textwrap
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/macos-ci.yml').read_text()
        block = workflow.split('          # Hosted identifiers', 1)[1].split('          ATTIC_VISUAL_UAT_DIRECTORY=', 1)[0]
        script = textwrap.dedent('# Hosted identifiers' + block) + '\nprintf "%s\\n" "$ui_scheme" "${skip_flags[@]}" "${identity_flags[@]}"'
        for selection, scheme, skipped in [
            ('', 'AtticUI', True),
            ('AtticUITests/TasksPageUITests', 'AtticUI', True),
            ('AtticUITests/PerformanceUITests/testTasksOpenMemoryAndCPU', 'AtticUI', False),
            ('AtticTests/FirstClickWindowServerTests', 'Attic', False),
        ]:
            with self.subTest(selection=selection):
                result = subprocess.run(['bash', '-c', script], env=dict(os.environ, UI_TESTS=selection),
                                        capture_output=True, text=True, check=True)
                self.assertEqual(result.stdout.splitlines()[0], scheme)
                self.assertEqual('-skip-testing:AtticUITests/PerformanceUITests' in result.stdout, skipped)
                if 'AtticUITests/PerformanceUITests' in selection:
                    self.assertIn('ATTIC_MACOS_BUNDLE_IDENTIFIER=com.taha.Attic.perf.ui', result.stdout)
                    self.assertIn('CODE_SIGNING_ALLOWED=YES', result.stdout)

    def test_optimized_reference_uses_historical_task_tests_with_current_cost_members(self):
        from prepare_cost_reference import INTEGRATION_MEMBERS
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/macos-ci.yml').read_text()
        job = workflow.split('  costs:', 1)[1].split('\n  performance:', 1)[0]
        self.assertIn('for fixture in DoneSearchCostTests TasksKeystrokeCostTests; do', job)
        self.assertEqual(INTEGRATION_MEMBERS['TaskPerformanceGateTests.swift'], (
            'seedStore', 'medianMilliseconds',
            'testFamilySummaryPassAtSixThousandTasksIsMilliseconds',
            'testStatusToggleAtSixThousandTasksStaysBounded',
        ))

    def test_ui_shards_cover_appearance_matrix_once_and_preserve_focused_selection(self):
        import os
        import subprocess
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/macos-ci.yml').read_text()
        job = workflow.split('  ui:', 1)[1].split('\n  costs:', 1)[0]
        self.assertIn("inputs.ui_tests && '[1]' || '[1, 2, 3]'", job)
        self.assertIn('name: macOS UI tests (${{ matrix.shard }} of 3)', job)
        flags_block = '          shard_flags=()' + job.split('          shard_flags=()', 1)[1].split('          # Hosted identifiers', 1)[0]

        def flags(shard, focused=''):
            script = flags_block.replace('${{ matrix.shard }}', str(shard))
            script += '\nprintf "%s\\n" "${shard_flags[@]}"'
            result = subprocess.run(['bash', '-c', script],
                                    env=dict(os.environ, UI_TESTS=focused),
                                    capture_output=True, text=True, check=True)
            return result.stdout.splitlines()

        appearance = 'AtticUITests/AtticUITests/testAppearanceControlsCoverEveryPaletteSurfaceAndTint'
        self.assertEqual(flags(1), [
            '-only-testing:AtticUITests/AtticUITests',
            '-only-testing:AtticUITests/CanvasUITests',
            '-only-testing:AtticUITests/NotesFormatUITests',
            f'-skip-testing:{appearance}',
        ])
        self.assertEqual(flags(2), [
            '-skip-testing:AtticUITests/AtticUITests',
            '-skip-testing:AtticUITests/CanvasUITests',
            '-skip-testing:AtticUITests/NotesFormatUITests',
            '-only-testing:AtticUITests',
        ])
        self.assertEqual(flags(3), [f'-only-testing:{appearance}'])
        self.assertEqual(flags(1, appearance), [f'-only-testing:{appearance}'])

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
        for job in ['fka', 'round-trips', 'notes-seeds', 'macos', 'unit-continuation', 'ui', 'costs', 'performance', 'appearance', 'iphone']:
            self.assertIn(f'  {job}:\n    needs: validate-inputs\n', workflow)

    def test_round_trips_are_a_required_parallel_job_without_reducing_coverage(self):
        root = Path(__file__).resolve().parent.parent
        workflow = (root / '.github/workflows/macos-ci.yml').read_text()
        job = workflow.split('  round-trips:', 1)[1].split('\n  macos:', 1)[0]
        self.assertIn('timeout-minutes: 70', job)
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
        self.assertIn('needs: [validate-inputs, macos, round-trips, notes-seeds, unit-continuation]', required)
        self.assertIn("always() && inputs.lane != 'costs' && inputs.lane != 'fka'", required)
        self.assertIn('MACOS_JOB: ${{ needs.macos.result }}', required)
        self.assertIn('ROUND_TRIPS: ${{ needs.round-trips.result }}', required)
        self.assertIn('NOTES_SEEDS: ${{ needs.notes-seeds.result }}', required)
        self.assertIn('UNIT_CONTINUATION: ${{ needs.unit-continuation.result }}', required)
        self.assertIn('python3 Scripts/ci_required_checks.py --parallel', required)

    def test_exhaustive_unit_suites_are_partitioned_across_required_runners(self):
        import re
        import subprocess
        import sys
        root = Path(__file__).resolve().parent.parent
        workflow = (root / '.github/workflows/macos-ci.yml').read_text()
        unit = workflow.split('      - name: Run macOS unit tests', 1)[1].split('      - name: Run native dropdown timing gates', 1)[0]
        continuation = workflow.split('  unit-continuation:', 1)[1].split('\n  required:', 1)[0]
        required = workflow.split('  required:', 1)[1].split('\n  ui:', 1)[0]

        script = root / 'Scripts/ci_unit_shards.py'
        expected = set()
        for source in (root / 'AtticTests').glob('*.swift'):
            expected.update(re.findall(r'^\s*(?:final\s+)?class\s+([\w]+)\s*:\s*XCTestCase\b',
                                           source.read_text(), re.MULTILINE))
        self.assertIn('O14FirstMouseTests', expected)
        only = subprocess.check_output([sys.executable, str(script), '--continuation-only'], text=True).splitlines()
        skips = subprocess.check_output([sys.executable, str(script), '--unit-skips'], text=True).splitlines()
        self.assertEqual({f.replace('-only-testing:', '-skip-testing:') for f in only}, set(skips))
        self.assertEqual(len(only), len(set(only)))
        self.assertTrue(set(s.split('/', 1)[1] for s in only).issubset(expected))
        self.assertIn('-only-testing:AtticTests/O14FirstMouseTests', only)
        self.assertNotIn('-only-testing:AtticTests/TasksFrameCostTests', only)
        self.assertNotIn('-only-testing:AtticTests/TasksRowBuildCostTests', only)
        self.assertTrue(all(s[0] >= 'P' or s == 'O14FirstMouseTests'
                            for s in (f.rsplit('/', 1)[-1] for f in only)))
        self.assertIn('python3 Scripts/ci_unit_shards.py --unit-skips', unit)
        self.assertIn('"${continuation_skips[@]}"', unit)
        self.assertIn('python3 Scripts/ci_unit_shards.py --continuation-only', continuation)
        self.assertIn('"${continuation_only[@]}"', continuation)
        self.assertIn('test-without-building', continuation)
        self.assertIn('passedTests', continuation)
        self.assertNotIn('continue-on-error', continuation)
        self.assertIn('UNIT_CONTINUATION: ${{ needs.unit-continuation.result }}', required)

    def test_all_notes_hunt_generated_seeds_have_one_dedicated_required_runner(self):
        import re
        root = Path(__file__).resolve().parent.parent
        source = (root / 'AtticTests/NotesEditorHuntTests.swift').read_text()
        workflow = (root / '.github/workflows/macos-ci.yml').read_text()
        seeds = re.findall(r'func testGeneratedSeed(\d+)\(', source)
        self.assertEqual(seeds, ['11012', '11013', '11014', '11015'])

        unit = workflow.split('      - name: Run macOS unit tests', 1)[1].split('      - name: Run native dropdown timing gates', 1)[0]
        job = workflow.split('  notes-seeds:', 1)[1].split('\n  macos:', 1)[0]
        required = workflow.split('  required:', 1)[1].split('\n  ui:', 1)[0]
        for seed in seeds:
            self.assertIn(f'-skip-testing:AtticTests/NotesEditorHuntTests/testGeneratedSeed{seed}', unit)
        self.assertIn('seed: [' + ', '.join(seeds) + ']', job)
        self.assertIn('-only-testing:AtticTests/NotesEditorHuntTests/testGeneratedSeed${{ matrix.seed }}', job)
        self.assertIn('timeout-minutes: 90', job)
        self.assertIn('fail-fast: false', job)
        self.assertNotIn('continue-on-error', job)
        self.assertIn('s["passedTests"]==1', job)
        self.assertIn('s["skippedTests"]==0', job)
        self.assertIn('s["failedTests"]==0', job)
        self.assertIn('NOTES_SEEDS: ${{ needs.notes-seeds.result }}', required)

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

    def test_unit_shards_bound_each_test_above_the_longest_measured_ci_test(self):
        root = Path(__file__).resolve().parent.parent
        workflow = (root / '.github/workflows/macos-ci.yml').read_text()
        main = workflow.split('      - name: Run macOS unit tests', 1)[1].split('      - name: Run native dropdown timing gates', 1)[0]
        continuation = workflow.split('  unit-continuation:', 1)[1].split('\n  required:', 1)[0]
        # 43338111674's xcresults: O14 233.730779 s; main maximum 103.989512 s.
        for shard in [main, continuation]:
            with self.subTest(shard='main' if shard == main else 'continuation'):
                self.assertIn('-test-timeouts-enabled YES', shard)
                self.assertIn('-default-test-execution-time-allowance 600', shard)
                self.assertIn('-maximum-test-execution-time-allowance 600', shard)
        self.assertIn('timeout-minutes: 60', main)
        self.assertIn('timeout-minutes: 55', continuation)
        summary = workflow.split('      - name: Print macOS unit-test summary', 1)[1].split('      - name: Upload macOS unit-test results', 1)[0]
        self.assertIn('if: always()', summary)
        self.assertIn('ci_required_checks.py --test-summary', summary)
        summary = continuation.split('      - name: Print continuation unit-test summary', 1)[1]
        self.assertIn('if: always()', summary)
        self.assertIn('ci_required_checks.py --test-summary', summary)

    def test_timeout_failure_is_named_in_the_step_summary_with_completed_tests(self):
        import json
        import os
        import subprocess
        import sys
        root = Path(__file__).resolve().parent.parent
        for failed in [False, True]:
            with self.subTest(failed=failed), tempfile.TemporaryDirectory() as directory:
                fixture = Path(directory) / 'tests.json'
                summary = Path(directory) / 'summary.md'
                fixture.write_text(json.dumps(dict(
                    passedTests=1, failedTests=int(failed), skippedTests=0, expectedFailures=0,
                    testFailures=[dict(testIdentifierString='TimeoutProbe/testATimesOut()',
                                       failureText='Test exceeded execution time allowance of 600 seconds')]
                    if failed else [])))
                env = dict(os.environ, **dict.fromkeys(CHECKS, 'success'),
                           LANE='full', GITHUB_STEP_SUMMARY=str(summary))
                result = subprocess.run([sys.executable, str(root / 'Scripts/ci_required_checks.py'),
                                         '--test-summary', str(fixture)], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, int(failed), result.stderr)
                report = summary.read_text()
                self.assertIn('| Passed | 1 |', report)
                self.assertIn(f'| Failed | {int(failed)} |', report)
                if failed:
                    self.assertIn('TimeoutProbe/testATimesOut()', report)
                    self.assertIn('execution time allowance of 600 seconds', report)
                    self.assertIn('::error', result.stdout)



if __name__ == '__main__':
    unittest.main()
