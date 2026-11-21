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
        for lane in ['', 'full', 'fast', 'costs', 'performance', 'fka']:
            for headless in ['true', 'false', '']:
                with self.subTest(lane=lane, headless=headless):
                    result = subprocess.run(['/bin/bash', '-e', '-c', script],
                        env=dict(os.environ, LANE=lane, HEADLESS_COSTS=headless, UI_TESTS=''), capture_output=True, text=True)
                    self.assertEqual(result.returncode, int(headless == 'true' and lane != 'costs'))
                    if result.returncode: self.assertIn('::error::headless_costs=true requires lane=costs', result.stdout)
            with self.subTest(lane=lane, ui_tests='AtticUITests/X'):
                result = subprocess.run(['/bin/bash', '-e', '-c', script],
                    env=dict(os.environ, LANE=lane, HEADLESS_COSTS='false', UI_TESTS='AtticUITests/X'), capture_output=True, text=True)
                self.assertEqual(result.returncode, int(lane == 'performance'))
                if result.returncode: self.assertIn('::error::ui_tests requires lane=full', result.stdout)
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

    def test_all_notes_hunt_generated_seeds_share_one_required_runner_with_one_process_each(self):
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
        self.assertIn('NOTES_SEEDS: ' + ' '.join(seeds) + '\n', job)
        self.assertEqual(job.count('build-for-testing'), 1)
        self.assertIn('for seed in $NOTES_SEEDS; do', job)
        self.assertIn('test-without-building', job)
        self.assertIn('-only-testing:AtticTests/NotesEditorHuntTests/testGeneratedSeed$seed', job)
        self.assertIn('failed="$failed $seed"', job)
        self.assertIn('if [ -n "$failed" ] || [ "$named" -eq 0 ] || [ "$passed" -ne "$named" ]; then', job)
        self.assertIn('NOTES_RESULT_TIMEOUT_SECONDS: 120\n', job)
        self.assertIn('NOTES_SEED_TIMEOUT_SECONDS: 1200\n', job)
        self.assertIn('kill -INT -- "-$pid"', job)
        self.assertIn('kill -KILL -- "-$pid"', job)
        self.assertIn('NOTES_SEED_HOST: AtticUnitTestHost\n', job)
        self.assertIn('else ps -x -U "$(id -u)" -o pid= -o comm=; fi', job)
        self.assertIn('else kill "$@"; fi', job)
        for seed in seeds:
            upload = job.split(f'      - name: Upload Notes editor generated seed {seed} evidence\n', 1)[1].split('\n      - ', 1)[0]
            self.assertIn(f'name: notes-editor-seed-{seed}-${{{{ github.sha }}}}', upload)
            self.assertIn(f'${{{{ runner.temp }}}}/notes-seed-{seed}/AtticNotesSeed.xcresult\n', upload)
            self.assertIn(f'${{{{ runner.temp }}}}/notes-seed-{seed}/notes-seed-summary.json\n', upload)
            self.assertIn('if: always()', upload)
        self.assertIn('timeout-minutes: 120', job)
        self.assertNotIn('continue-on-error', job)
        self.assertIn('s["passedTests"]==1', job)
        self.assertIn('s["skippedTests"]==0', job)
        self.assertIn('s["failedTests"]==0', job)
        self.assertIn('NOTES_SEEDS: ${{ needs.notes-seeds.result }}', required)

    def test_performance_and_costs_run_on_their_own_lanes_and_on_main_pushes_only(self):
        import re
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/macos-ci.yml').read_text()
        conditions = dict(re.findall(r'\n  ([a-z-]+):\n    needs: [^\n]+\n(?:    [a-z-]+: [^\n]+\n)?    if: \$\{\{ ([^\n]+) \}\}\n', workflow))
        self.assertEqual(conditions['costs'], "(github.event_name != 'workflow_dispatch' || inputs.lane == 'costs') && !inputs.ui_tests")
        self.assertEqual(conditions['performance'], "(github.event_name != 'workflow_dispatch' || inputs.lane == 'performance') && !inputs.ui_tests")
        self.assertIn('options: [full, fast, costs, performance, fka]', workflow)
        for job in ['round-trips', 'notes-seeds', 'macos', 'unit-continuation', 'required', 'ui', 'appearance', 'iphone', 'canvas-lab']:
            with self.subTest(job=job):
                self.assertIn("inputs.lane != 'performance'", conditions[job])
        self.assertIn("inputs.lane == 'fka' || inputs.lane == 'full'", conditions['fka'])
        self.assertIn('group: attic-ci-${{ github.workflow }}-${{ github.ref }}-${{ inputs.lane }}\n', workflow)

    def test_lane_routing_runs_only_the_named_dedicated_lane(self):
        import re
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/macos-ci.yml').read_text()
        conditions = dict(re.findall(r'\n  ([a-z-]+):\n    needs: [^\n]+\n(?:    [a-z-]+: [^\n]+\n)?    if: \$\{\{ ([^\n]+) \}\}\n', workflow))
        def runs(condition, event, lane, ui_tests='', run_iphone=False):
            expression = (condition.replace('&&', ' and ').replace('||', ' or ').replace('always()', 'True')
                          .replace('!inputs.', 'not inputs.').replace('github.event_name', 'event')
                          .replace('inputs.lane', 'lane').replace('inputs.ui_tests', 'ui_tests')
                          .replace('inputs.run_iphone', 'run_iphone'))
            return eval(expression, {}, dict(event=event, lane=lane, ui_tests=ui_tests, run_iphone=run_iphone))
        everything = set(conditions)
        expected = {
            'performance': {'performance'},
            'costs': {'costs'},
            'fka': {'fka'},
            'fast': {'round-trips', 'notes-seeds', 'macos', 'unit-continuation', 'required', 'canvas-lab'},
            'full': everything - {'costs', 'performance', 'iphone'},
        }
        for lane, jobs in expected.items():
            with self.subTest(lane=lane):
                self.assertEqual({job for job, condition in conditions.items() if runs(condition, 'workflow_dispatch', lane)}, jobs)
        self.assertFalse(runs(conditions['fka'], 'workflow_dispatch', 'performance'))
        self.assertEqual({job for job, condition in conditions.items() if runs(condition, 'push', '')}, everything - {'iphone'})

    def test_notes_seed_loop_runs_every_seed_and_fails_unless_all_named_seeds_pass(self):
        import os
        import stat
        import subprocess
        workflow = (Path(__file__).resolve().parent.parent / '.github/workflows/macos-ci.yml').read_text()
        job = workflow.split('  notes-seeds:', 1)[1].split('\n  macos:', 1)[0]
        step = job.split('      - name: Verify every complete generated Notes editor seed\n', 1)[1].split('\n      - name:', 1)[0]
        script = '\n'.join(line[10:] for line in step.split('        run: |\n', 1)[1].splitlines())
        host_rel = 'AtticNotesSeed/Build/Products/Local/AtticUnitTestHost.app/Contents/MacOS/AtticUnitTestHost'
        # The process table and signals are simulated: the loop never looks up
        # or signals a live process other than the stubs it starts itself.
        # 101 and 202 run this job's host path before the step. During every
        # seed the stub test adds 303, the same suffix under another root.
        # Modes add this seed's own hosts (9001, 9002) at the job's path.
        stub_test = ('#!/bin/bash\nseed=$(printf "%s\\n" "$@" | sed -n "s/.*testGeneratedSeed//p")\n'
                     'echo "test $seed leftover:$(grep -v "^101 \\|^202 \\|^303 " "$TABLE" | tr "\\n" ,)" >> "$CALLS"\n'
                     'grep -q "^303 " "$TABLE" || echo "303 $RUNNER_TEMP/other-root/' + host_rel + '" >> "$TABLE"\n'
                     'host="$RUNNER_TEMP/' + host_rel + '"\n'
                     'if [ "$seed" = "$FAIL_SEED" ]; then\n'
                     '  case "$MODE" in\n'
                     '    fail) exit 65 ;;\n'
                     '    leave-host|leave-stubborn-host|replace-host) echo "9001 $host" >> "$TABLE"; exit 65 ;;\n'
                     '    leave-two-stubborn-hosts) printf "9001 %s\\n9002 %s\\n" "$host" "$host" >> "$TABLE"; exit 65 ;;\n'
                     '    pass-leave-unkillable-host) echo "9001 $host" >> "$TABLE"; exit 0 ;;\n'
                     '    hang) /bin/sleep 30 ;;\n'
                     '  esac\n'
                     'fi\nexit 0\n')
        stub_xcrun = ('#!/bin/bash\necho "read" >> "$CALLS"\n'
                      'case "$*" in *notes-seed-$FAIL_SEED/*) [ "$MODE" = reader-hang ] && /bin/sleep 30 ;; esac\n'
                      'echo \'{"passedTests":1,"failedTests":0,"skippedTests":0,"expectedFailures":0}\'\n')
        stub_table = '#!/bin/bash\ncat "$TABLE"\n'
        # TERM ends a host unless it is stubborn; replace-host's TERM starts a
        # same-path successor 9002; KILL ends any host except an unkillable one.
        stub_signal = ('#!/bin/bash\necho "$1 $2" >> "$SIGNALS"\n'
                       'drop() { grep -v "^$1 " "$TABLE" > "$TABLE.new"; mv "$TABLE.new" "$TABLE"; }\n'
                       'case "$MODE:$1:$2" in\n'
                       '  pass-leave-unkillable-host:*) ;;\n'
                       '  leave-stubborn-host:-TERM:*|leave-two-stubborn-hosts:-TERM:*) ;;\n'
                       '  replace-host:-TERM:9001) drop 9001; echo "9002 $(awk \'$1 == 101 { print $2 }\' "$TABLE")" >> "$TABLE" ;;\n'
                       '  *) drop "$2" ;;\n'
                       'esac\n')
        # Cleanup's 1 s sleeps return at once and are counted; longer sleeps
        # (the watchdog's limits) are real.
        stub_sleep = '#!/bin/bash\nif [ "$1" = 1 ]; then echo 1 >> "$SLEEPS"; exit 0; fi\nexec /bin/sleep "$@"\n'
        cases = [  # (seeds, fail seed, mode, exit code, test runs, signals, max 1 s sleeps or None)
            ('11012 11013 11014 11015', '', 'pass', 0, 4, [], None),
            ('11012 11013 11014 11015', '11013', 'fail', 1, 4, [], None),
            ('11012 11013 11014 11015', '11013', 'leave-host', 1, 4, ['-TERM 9001'], None),
            ('11012 11013 11014 11015', '11013', 'leave-stubborn-host', 1, 4, ['-TERM 9001', '-KILL 9001'], None),
            # 9002 appears during the grace, so it is caught by the KILL rescan.
            ('11012 11013 11014 11015', '11013', 'replace-host', 1, 4, ['-TERM 9001', '-KILL 9002'], None),
            # One shared 10 s grace for both hosts: 5 + 10 + 1 sleeps at most.
            ('11012 11013 11014 11015', '11013', 'leave-two-stubborn-hosts', 1, 4,
             ['-TERM 9001', '-TERM 9002', '-KILL 9001', '-KILL 9002'], 16),
            ('11012 11013 11014 11015', '11013', 'pass-leave-unkillable-host', 1, 4,
             ['-TERM 9001', '-KILL 9001'] * 3, None),
            ('11012 11013 11014 11015', '11013', 'hang', 1, 4, [], None),
            ('11012 11013 11014 11015', '11012', 'reader-hang', 1, 4, [], None),
            ('', '', 'pass', 1, 0, [], None),
            ('11012 1101x 11014 11015', '', 'pass', 1, 3, [], None),
        ]
        for seeds, fail_seed, mode, code, runs, signals, max_sleeps in cases:
            with self.subTest(seeds=seeds, fail_seed=fail_seed, mode=mode), tempfile.TemporaryDirectory() as tmp:
                tmp = Path(tmp)
                (tmp / 'Scripts').mkdir()
                (tmp / 'bin').mkdir()
                for path, body in [(tmp / 'Scripts/xcodebuild_locked.sh', stub_test), (tmp / 'bin/xcrun', stub_xcrun),
                                   (tmp / 'bin/table', stub_table), (tmp / 'bin/signal', stub_signal),
                                   (tmp / 'bin/sleep', stub_sleep)]:
                    path.write_text(body)
                    path.chmod(path.stat().st_mode | stat.S_IEXEC)
                (tmp / 'table').write_text(f'101 {tmp}/{host_rel}\n202 {tmp}/{host_rel}\n')
                env = dict(os.environ, PATH=f"{tmp / 'bin'}:{os.environ['PATH']}", RUNNER_TEMP=str(tmp),
                           CALLS=str(tmp / 'calls'), FAIL_SEED=fail_seed, MODE=mode, NOTES_SEEDS=seeds,
                           TABLE=str(tmp / 'table'), SIGNALS=str(tmp / 'signals'), SLEEPS=str(tmp / 'sleeps'),
                           NOTES_PROCESS_TABLE=str(tmp / 'bin/table'), NOTES_SIGNAL=str(tmp / 'bin/signal'),
                           NOTES_SEED_HOST='AtticUnitTestHost', NOTES_SEED_TIMEOUT_SECONDS='2',
                           NOTES_RESULT_TIMEOUT_SECONDS='2')
                result = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-e', '-c', script], cwd=tmp, env=env,
                                        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
                calls = (tmp / 'calls').read_text().splitlines() if (tmp / 'calls').exists() else []
                sent = (tmp / 'signals').read_text().splitlines() if (tmp / 'signals').exists() else []
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                self.assertEqual(sum(line.startswith('test ') for line in calls), runs, calls)
                self.assertEqual(sent, signals, result.stdout)
                table = (tmp / 'table').read_text()
                for survivor in ['101 ', '202 '] + (['303 '] if runs else []):
                    self.assertIn(survivor, table)
                if mode == 'pass-leave-unkillable-host':
                    self.assertIn('still running after 3 cleanup passes', result.stdout)
                    self.assertIn('failed: 11013', result.stdout)
                else:
                    # No host of a seed is still there when the next seed starts.
                    self.assertTrue(all(line.endswith('leftover:') for line in calls if line.startswith('test ')), calls)
                if max_sleeps is not None:
                    sleeps = len((tmp / 'sleeps').read_text().splitlines()) if (tmp / 'sleeps').exists() else 0
                    self.assertLessEqual(sleeps, max_sleeps)
                if mode in ('hang', 'reader-hang'):
                    self.assertIn('timed out after 2 s', result.stdout)

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
        # Only the test-without-building invocation counts: flags on build-for-testing do nothing.
        main_run = main.split('Scripts/xcodebuild_locked.sh \\\n', 1)[1].split('test-without-building', 1)[0]
        continuation_run = continuation.split('Scripts/xcodebuild_locked.sh test-without-building', 1)[1].split('\n      - name:', 1)[0]
        # 43338111674's xcresults: O14 233.730779 s; main maximum 103.989512 s.
        for name, run, allowance in [('main', main_run, 240), ('continuation', continuation_run, 360)]:
            with self.subTest(shard=name):
                self.assertIn('-test-timeouts-enabled YES', run)
                self.assertIn(f'-default-test-execution-time-allowance {allowance}', run)
                self.assertIn(f'-maximum-test-execution-time-allowance {allowance}', run)
        self.assertIn('timeout-minutes: 60', main)
        self.assertIn('timeout-minutes: 55', continuation)
        summary = workflow.split('      - name: Print macOS unit-test summary', 1)[1].split('      - name: Upload macOS unit-test results', 1)[0]
        self.assertIn('if: always()', summary)
        # A red summary reports; it must not skip the steps after it. The gate reads unit_tests.outcome.
        self.assertIn('continue-on-error: true', summary)
        self.assertIn('ci_required_checks.py --test-summary', summary)
        summary = continuation.split('      - name: Print continuation unit-test summary', 1)[1].split('      - name: Upload continuation XCTest result', 1)[0]
        self.assertIn('if: always()', summary)
        self.assertIn('[ ! -d "$RUNNER_TEMP/AtticUnitContinuation.xcresult" ]', summary)
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
