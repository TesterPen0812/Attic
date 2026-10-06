"""OD-17 plumbing: propagate parts, keep OD-15 and nonderived bounds."""
from pathlib import Path
import os
import re
import tempfile
import unittest

from check_integration_costs import DERIVED, control_samples
from cost_resolution import compare, compare_derived
from recheck_cost_gates import check, Sampler, INTEGRATION_TESTS
from unittest.mock import patch
import contextlib
import io
import test_cost_recheck as recheck_tests

logs = recheck_tests.logs


def difference_logs(root, name, regression=False):
    logs(root)
    full, empty = DERIVED[name]
    for side in ('baseline', 'candidate'):
        for index in range(3):
            a = b = 20 + index
            if side == 'candidate':
                a = a * 1.3 if regression else 22.3
                b = b if regression else 20
            values = {full: a, empty: b, name: a - b}
            path = root / f'integration-{side}-{index + 1}.log'
            text = path.read_text()
            for metric, value in values.items():
                if metric == 'recovery-control':
                    text = re.sub(r'NOTE_RECOVERY_CONTROL_MAIN_ACTOR_MS_MEDIAN=\S+',
                                  f'NOTE_RECOVERY_CONTROL_MAIN_ACTOR_MS_MEDIAN={value}', text)
                else:
                    text = re.sub(rf'(ATTIC_INTEGRATION_COST {metric} median_ms=)\S+',
                                  lambda m: m[1] + str(value), text)
            path.write_text(text)


class DerivedCostsTests(unittest.TestCase):
    run_gate = recheck_tests.CostRecheckTests.run_gate

    def test_headless_sampler_selects_only_headless_integration_tests(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, RUNNER_TEMP=tmp, COST_FLAGS=''):
            sampler = Sampler()
            calls = []
            def run(directory, side, build, tests, filename):
                calls.append(side)
                self.assertEqual(tests, INTEGRATION_TESTS[:-1])
                return ''
            with patch.object(sampler, 'run', run):
                sampler('integration-headless', Path(tmp) / 'retry')
            self.assertEqual(calls, ['baseline', 'candidate', 'candidate', 'baseline', 'baseline', 'candidate'])

    def test_explicit_headless_gate_never_requires_key_window_samples(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            difference_logs(root, 'scaling-attachment-save', regression=True)
            (root / 'done-search.log').unlink()
            calls = []
            def retry(family, directory):
                calls.append(family)
                difference_logs(directory, 'scaling-attachment-save', regression=True)
                (directory / 'done-search.log').unlink()
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(check(root, retry, ['integration-headless']), 1)
            self.assertEqual(calls, ['integration-headless'])

    def test_every_difference_accepts_component_wobble(self):
        for name in DERIVED:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                difference_logs(root, name)
                status, report = self.run_gate(root, lambda *args: self.fail('unnecessary retry'))
                row = report['families']['integration'][name]
                self.assertEqual(status, 0)
                self.assertEqual(len(row['attempts']), 1)
                attempt = row['attempts'][0]
                self.assertAlmostEqual(attempt['bound_ms'], 4.4)
                self.assertAlmostEqual(attempt['noise_ms'], sum(
                    part['noise_ms'] for part in attempt['components'].values()))
                self.assertEqual(attempt['derived_range_ms'], 0)

    def test_one_component_30_percent_slower_fails_twice(self):
        for name in DERIVED:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                difference_logs(root, name, regression=True)
                calls = []
                def retry(family, directory):
                    calls.append(family)
                    difference_logs(directory, name, regression=True)
                status, report = self.run_gate(root, retry)
                self.assertEqual(status, 1)
                self.assertEqual(calls, ['integration'])
                attempts = report['families']['integration'][name]['attempts']
                self.assertEqual([x['passed'] for x in attempts], [False, False])
                self.assertTrue(all(x['bound_ms'] == 4.4 for x in attempts))

    def test_component_resolution_and_rounding_allowances_are_added(self):
        parts = {'full': compare([20] * 3, [20] * 3, reference_samples=[20, 21]),
                 'empty': compare([20] * 3, [20] * 3, quantum_ms=2)}
        row = compare_derived([0] * 3, [3.4] * 3, parts)
        self.assertAlmostEqual(row['noise_ms'], 3.4)
        self.assertTrue(row['passed'])
        self.assertFalse(compare_derived([-100, 0, 100], [4] * 3, parts)['passed'])
        self.assertEqual(compare_derived([0] * 3, [4, 4, 999], parts)['bound_ms'], row['bound_ms'])

    def test_recovery_control_uses_existing_paired_raw_samples(self):
        text = ('ATTIC_COST_SAMPLES metric=recovery-main-actor raw_ms=[21, 22, 23]\n'
                'ATTIC_COST_SAMPLES metric=recovery-overhead raw_ms=[1, 0, -1]\n')
        self.assertEqual(control_samples([text]), [20, 22, 24])
        with self.assertRaises(ValueError):
            control_samples([text.replace('[1, 0, -1]', '[1, 0]')])


if __name__ == '__main__':
    unittest.main()
