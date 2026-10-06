import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from check_integration_costs import METRICS
from recheck_cost_gates import check, paired_order, Sampler, ROOT


def logs(root, candidate=10, reference=10):
    root.mkdir(parents=True, exist_ok=True)
    for side, value in [('baseline', reference), ('candidate', candidate)]:
        for sample in (1, 2, 3):
            frame = 'ATTIC_FRAME_COST feel=Lively | ' + ' | '.join(
                f'{metric} n=3 median={value}ms max={value}ms' for metric in
                ['select-1-page', 'select-3-pages', 'swipe-follow-frames', 'swipe-settle-frames',
                 'keystroke', 'title-keystroke', 'search-keystroke'])
            frame += f' | click-first now={value}ms backlog={value}ms done={value}ms\n'
            row = f'ATTIC_ROW_BUILD empty=0ms rows=+{value}ms lazy-scroll=+{value}ms\n'
            (root / f'{side}-cost-{sample}.log').write_text(frame + row)
            cost = ''.join(f'ATTIC_INTEGRATION_COST {name} median_ms={value}\n' for name in METRICS)
            cost += 'NOTE_RECOVERY_CONTROL_MAIN_ACTOR_MS_MEDIAN=0\n'
            if side == 'baseline' and sample == 1:
                cost += rendered(value)
            (root / f'integration-{side}-{sample}.log').write_text(cost)
    for sample in (1, 2, 3):
        (root / f'done-search-baseline-{sample}.log').write_text(
            ''.join(memory(session, reference) for session in range(3)) + disk('', reference))
    (root / 'done-search.log').write_text(rendered(candidate) + ''.join(
        memory(session, candidate) + disk(f'session={session} ', candidate) for session in range(3)))


def memory(session, value):
    return f'ATTIC_DONE_SEARCH session={session} query=F page/group/count_ms=[] total_ms={value}\n'


def disk(session, value):
    return f'ATTIC_PHASE5_DONE {session}query=F legacy_page_count_lower_bound_ms=1 indexed_page_group_count_ms={value}\n'


def rendered(value):
    return ''.join(f'ATTIC_DONE_RESULTS run={i} frame_ms={value}\n' for i in range(3)) + ''.join(
        f'ATTIC_DONE_KEY key={i} raw_ms=[{value}, {value}, {value}]\n' for i in range(len('Finished task 12')))


class CostRecheckTests(unittest.TestCase):
    def run_gate(self, root, sampler):
        with contextlib.redirect_stdout(io.StringIO()):
            status = check(root, sampler)
        return status, json.loads((root / 'cost-gate-attempts.json').read_text())

    def test_pass_needs_no_recheck(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            logs(root)
            calls = []
            status, report = self.run_gate(root, lambda *args: calls.append(args))
            self.assertEqual(status, 0)
            self.assertEqual(calls, [])
            self.assertTrue(all(len(row['attempts']) == 1 for rows in report['families'].values() for row in rows.values()))

    def test_one_off_fail_passes_once_recheck_passes_in_every_family(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            logs(root, candidate=12)
            calls = []
            def resample(family, directory):
                calls.append(family)
                logs(directory)
            status, report = self.run_gate(root, resample)
            self.assertEqual(status, 0)
            self.assertEqual(calls, ['frame-row', 'integration', 'done-query'])
            for rows in report['families'].values():
                for row in rows.values():
                    self.assertEqual([x['passed'] for x in row['attempts']], [False, True])
                    self.assertTrue(row['passed'])
            summary = (root / 'cost-gate-summary.md').read_text()
            self.assertIn('| 1 |', summary)
            self.assertIn('| 2 |', summary)

    def test_real_fail_fails_twice_without_a_third_attempt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            logs(root, candidate=12)
            calls = []
            def resample(family, directory):
                calls.append(family)
                logs(directory, candidate=12)
            status, report = self.run_gate(root, resample)
            self.assertEqual(status, 1)
            self.assertEqual(len(calls), 3)
            for rows in report['families'].values():
                for row in rows.values():
                    self.assertEqual([x['passed'] for x in row['attempts']], [False, False])

    def test_missing_initial_or_recheck_sample_fails_closed(self):
        for family, filename in [('frame-row', 'candidate-cost-2.log'),
                                 ('integration', 'integration-candidate-2.log'),
                                 ('done-query', 'done-search-baseline-2.log')]:
            for retry in (False, True):
                with self.subTest(family=family, retry=retry), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    logs(root, candidate=12 if retry else 10)
                    if not retry:
                        (root / filename).unlink()
                    def resample(name, directory):
                        logs(directory)
                        if name == family:
                            (directory / filename).unlink()
                    status, report = self.run_gate(root, resample)
                    self.assertEqual(status, 1)
                    self.assertIn(family, report['errors'])

    def test_reference_only_budget_breach_does_not_fail_comparison(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            logs(root, reference=600)  # Includes reference Done 500 ms sanity overage.
            status, report = self.run_gate(root, lambda *args: self.fail('unnecessary recheck'))
            self.assertEqual(status, 0)
            self.assertTrue(report['passed'])

    def test_first_pass_stays_accepted_and_second_attempt_recalibrates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            logs(root, candidate=12)
            # One row passes on attempt one; shared fixture later emits a failure.
            for sample in (1, 2, 3):
                path = root / f'integration-candidate-{sample}.log'
                path.write_text(path.read_text().replace('family-summary median_ms=12', 'family-summary median_ms=10'))
            def resample(family, directory):
                logs(directory, reference=80, candidate=80)
                if family == 'integration':
                    for sample in (1, 2, 3):
                        path = directory / f'integration-candidate-{sample}.log'
                        path.write_text(path.read_text().replace('family-summary median_ms=80', 'family-summary median_ms=82'))
            status, report = self.run_gate(root, resample)
            self.assertEqual(status, 0)
            family = report['families']['integration']
            self.assertEqual(len(family['family-summary']['attempts']), 1)
            self.assertEqual(family['status-toggle']['attempts'][1]['bound_ms'], 80.2)
            raw = json.loads((root / 'recheck/integration/integration-cost-comparison.json').read_text())
            self.assertFalse(raw['family-summary']['passed'])

    def test_recheck_process_failure_is_not_a_timing_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            logs(root, candidate=12)
            def fail(*args):
                raise RuntimeError('candidate absolute/functional failure')
            status, report = self.run_gate(root, fail)
            self.assertEqual(status, 1)
            self.assertEqual(set(report['errors']), {'frame-row', 'integration', 'done-query'})

    def test_real_sampler_interleaves_and_normalizes_three_query_sessions(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, RUNNER_TEMP=tmp, COST_FLAGS=''):
            sampler = Sampler()
            calls = []
            def run(directory, side, build, tests, filename):
                calls.append((side, build, filename))
                if side == 'baseline':
                    return ''.join(memory(i, 10) for i in range(3)) + disk('', 10)
                return ''.join(memory(i, 10) + disk(f'session={i} ', 10) for i in range(3))
            with patch.object(sampler, 'run', run):
                retry = Path(tmp) / 'retry'
                sampler('done-query', retry)
            self.assertEqual([side for side, _, _ in calls], ['baseline', 'candidate', 'candidate', 'baseline', 'baseline', 'candidate'])
            import check_done_search_costs
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(check_done_search_costs.main(retry), 0)
            self.assertEqual([paired_order(i) for i in (1, 2, 3)],
                             [('baseline', 'candidate'), ('candidate', 'baseline'), ('baseline', 'candidate')])

    def test_reference_flag_and_lock_are_set_for_every_sampler_process(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, RUNNER_TEMP=tmp, COST_FLAGS=''):
            sampler = Sampler()
            root = Path(tmp)
            def process(args, **kwargs):
                self.assertEqual(args[0], str(ROOT / 'Scripts/xcodebuild_locked.sh'))
                expected = '0' if kwargs['cwd'] == ROOT else '1'
                self.assertEqual(kwargs['env']['TEST_RUNNER_ATTIC_COST_REFERENCE_ONLY'], expected)
                return type('Result', (), {'returncode': 0})()
            with patch('recheck_cost_gates.subprocess.run', process):
                sampler.run(root, 'baseline', 'integrationbase', [], 'reference.log')
                sampler.run(root, 'candidate', 'candidate', [], 'candidate.log')


if __name__ == '__main__':
    unittest.main()
