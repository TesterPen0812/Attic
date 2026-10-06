import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from recheck_pf_gates import check, Sampler, TESTS
from test_pf_paired_gate import fixture, log


def samples(root, candidate=3, after=None, metric='EMPTY_OPEN_MS'):
    root.mkdir(parents=True, exist_ok=True)
    base, actual = fixture(), fixture()
    actual['PF'][metric] = [candidate] * 3
    for name, value in [('base', base), ('candidate', actual), ('base-after', after or base)]:
        (root / f'pf-{name}.log').write_text(log(value))


class PFRecheckTests(unittest.TestCase):
    def run_gate(self, root, sampler, prior=()):
        with contextlib.redirect_stdout(io.StringIO()):
            code = check(root, sampler, prior)
        return code, json.loads((root / 'pf-gate-attempts.json').read_text())

    def test_pinned_pf_reference_adapts_only_four_timing_assertions(self):
        import subprocess
        import prepare_cost_reference, prepare_pf_reference
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root/'AtticTests').mkdir()
            originals = {}
            for name in ['TasksFrameCostTests', 'NotesPageControllerTests']:
                originals[name] = subprocess.check_output(['git', 'show', f'd77ec80:AtticTests/{name}.swift'], text=True)
                (root/f'AtticTests/{name}.swift').write_text(originals[name])
            prepare_cost_reference.prepare(root, 'frame-row')
            prepare_pf_reference.prepare(root)
            adapted = (root/'AtticTests/NotesPageControllerTests.swift').read_text()
            for assertion in prepare_pf_reference.REPLACEMENTS:
                adapted = adapted.replace(assertion.replace('XCTAssert', 'CostBudget.assert'), assertion)
            self.assertEqual(adapted, originals['NotesPageControllerTests'])

    def test_first_pass_needs_no_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); samples(root)
            self.assertEqual(self.run_gate(root, lambda *_: self.fail('unnecessary retry'))[0], 0)

    def test_single_failure_passes_on_recheck_real_failure_fails_twice(self):
        for second, expected in [(3, 0), (6, 1)]:
            with self.subTest(second=second), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); samples(root, candidate=6)
                calls = []
                def sampler(directory):
                    calls.append(directory); samples(directory, candidate=second)
                code, evidence = self.run_gate(root, sampler)
                self.assertEqual(code, expected); self.assertEqual(len(calls), 1)
                row = evidence['runs'][0]['rows']['PF_EMPTY_OPEN_MS']
                self.assertEqual([a['passed'] for a in row['attempts']], [False, second == 3])
                self.assertEqual(len(evidence['runs'][0]['rows']['PF_EMPTY_SAVE_MS']['attempts']), 1)

    def test_missing_initial_or_retry_data_fails_closed(self):
        for retry in [False, True]:
            with self.subTest(retry=retry), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); samples(root, candidate=6 if retry else 3)
                if not retry: (root / 'pf-base.log').unlink()
                def sampler(directory):
                    samples(directory); (directory / 'pf-candidate.log').unlink()
                self.assertEqual(self.run_gate(root, sampler)[0], 3)

    def test_unmeasurable_retry_cannot_turn_failure_into_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); samples(root, candidate=6)
            after = fixture(); after['PF']['EMPTY_OPEN_MS'] = [9] * 3
            code, evidence = self.run_gate(root, lambda directory: samples(directory, candidate=6, after=after))
            self.assertEqual(code, 2)
            self.assertIn('PF_EMPTY_OPEN_MS', evidence['unmeasurable'])

    def test_first_passing_rows_stay_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); samples(root, candidate=6)
            def sampler(directory):
                samples(directory)
                run = fixture(); run['PF']['EMPTY_SAVE_MS'] = [9] * 3
                (directory / 'pf-candidate.log').write_text(log(run))
            code, evidence = self.run_gate(root, sampler)
            self.assertEqual(code, 0)
            self.assertEqual(len(evidence['runs'][0]['rows']['PF_EMPTY_SAVE_MS']['attempts']), 1)

    def test_failed_process_is_not_a_timing_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); samples(root, candidate=6)
            def sampler(_): raise RuntimeError('functional/absolute budget failure')
            self.assertEqual(self.run_gate(root, sampler)[0], 3)

    def test_exact_sha_carry_includes_raw_recheck_and_keeps_unmeasurable(self):
        with tempfile.TemporaryDirectory() as tmp:
            prior, root = Path(tmp)/'prior', Path(tmp)/'now'
            after = fixture(); after['PF']['EMPTY_OPEN_MS'] = [9] * 3
            samples(prior, after=after); samples(prior/'pf-recheck', after=after)
            samples(root)
            self.assertEqual(self.run_gate(root, lambda _: self.fail('unnecessary retry'), [prior])[0], 0)
            self.assertEqual(self.run_gate(root, lambda _: None, [prior, prior])[0], 3)

    def test_sampler_is_locked_fixture_interleaved_and_reference_only(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, RUNNER_TEMP=tmp, PF_COST_FLAGS=''):
            calls=[]
            def run(args, **kwargs):
                if 'test-without-building' in args:
                    self.assertTrue(args[0].endswith('xcodebuild-locked.sh'))
                    calls.append(kwargs['env']['TEST_RUNNER_ATTIC_COST_REFERENCE_ONLY'])
                return type('Result', (), {'returncode': 0})()
            with patch('recheck_pf_gates.subprocess.run', run): Sampler()(Path(tmp)/'retry')
            self.assertEqual(calls, ['1', '0', '1'] * len(TESTS))


if __name__ == '__main__': unittest.main()
