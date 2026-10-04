#!/usr/bin/env python3
"""Synthetic regression tests for the paired gate; no hosted data required."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import pf_paired_gate as gate


def fixture():
    return {'PF': {key: [1, 2, 3] for key in gate.PF_KEYS | gate.COLD_KEYS},
            'PF1': {key: [1, 2, 3] for key in gate.PF1_KEYS},
            'PF5': {key: [1] * 40 for key in gate.PF5_KEYS}}


def log(run, prefix=''):
    lines = [name + '_REFERENCE_JSON=' + json.dumps({k: {'values': v} for k, v in run[name].items()})
             for name in ('PF', 'PF1')]
    lines += ['PF5_SAMPLES_' + k + '=' + ','.join(map(str, v)) for k, v in run['PF5'].items()]
    return '\n'.join(prefix + line for line in lines) + '\n'


class PairedGateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def write(self, name, run):
        path = Path(self.directory.name) / name
        path.write_text(log(run))
        return str(path)

    def run_gate(self, base, candidate, after=None):
        args = ['--base', self.write('base', base), '--candidate', self.write('candidate', candidate)]
        if after is not None:
            args += ['--base-after', self.write('after', after)]
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = gate.main(args)
        return code, output.getvalue()

    def test_raw_and_github_logs_last_copy(self):
        first, last = fixture(), fixture()
        last['PF']['EMPTY_SAVE_MS'] = [4, 5, 6]
        last['PF1']['EMPTY_AUTOSAVE_5000_MS'] = [4, 5, 6]
        last['PF5']['EMPTY_TOGGLE_Q1_MS'] = [2] * 40
        for prefix in ('', 'foundation\tMeasure fixed Phase 2 reference on this runner\t2026-10-03T12:00:00Z '):
            path = Path(self.directory.name) / 'log'
            path.write_text(log(first, prefix) + log(last, prefix))
            self.assertEqual(gate.parse_log(path), last)

    def test_binomial_tail(self):
        self.assertAlmostEqual(gate.binomial_tail(10, 10, 0.5), 2 ** -10)
        self.assertEqual(gate.binomial_tail(0, 0, 1 / 3), 1)
        self.assertAlmostEqual(gate.binomial_tail(1, 2, 0.5), 0.75)

    def test_exit_pass(self):
        self.assertEqual(self.run_gate(fixture(), fixture())[0], 0)
        self.assertEqual(self.run_gate(fixture(), fixture(), fixture())[0], 0)

    def test_exit_candidate_failure(self):
        changed = fixture()
        changed['PF1']['EMPTY_AUTOSAVE_5000_MS'] = [6, 6, 6]
        self.assertEqual(self.run_gate(fixture(), changed, fixture())[0], 1)

    def test_exit_unmeasurable_bidirectional_and_ceiling(self):
        after = fixture()
        after['PF1']['EMPTY_AUTOSAVE_5000_MS'] = [6, 6, 6]
        self.assertEqual(self.run_gate(fixture(), fixture(), after)[0], 2)
        self.assertEqual(self.run_gate(after, fixture(), fixture())[0], 2)
        base = fixture()
        base['PF']['SIX_THOUSAND_TOGGLE_MS'] = [1, 2, 121]
        self.assertEqual(self.run_gate(base, fixture(), base)[0], 2)

    def test_accepted_memory_is_bounded_and_does_not_relax_aa(self):
        candidate = fixture()
        candidate['PF']['POPULATED_OPEN_GROWTH_MB'] = [9.75] * 3
        self.assertEqual(self.run_gate(fixture(), candidate, fixture())[0], 0)
        candidate['PF']['POPULATED_OPEN_GROWTH_MB'] = [9.751] * 3
        self.assertEqual(self.run_gate(fixture(), candidate, fixture())[0], 1)
        candidate['PF']['POPULATED_OPEN_GROWTH_MB'] = [6] * 3
        self.assertEqual(self.run_gate(fixture(), fixture(), candidate)[0], 2)
        candidate = fixture()
        candidate['PF']['EMPTY_OPEN_GROWTH_MB'] = [5.01] * 3
        self.assertEqual(self.run_gate(fixture(), candidate, fixture())[0], 1)

    def test_growth_keys_required_and_diagnostics_ignored(self):
        run = fixture()
        self.assertIn('EMPTY_OPEN_GROWTH_MB', gate.PF_KEYS)
        self.assertIn('POPULATED_OPEN_GROWTH_MB', gate.PF_KEYS)
        path = Path(self.directory.name) / 'diagnostic'
        path.write_text(log(run) + 'PF_DIAG_OPEN_FOOTPRINT=not gate JSON\n')
        self.assertEqual(gate.parse_log(path), run)
        for fixture_name in gate.FIXTURES:
            old = fixture()
            old['PF'][fixture_name + '_OPEN_PEAK_MB'] = old['PF'].pop(fixture_name + '_OPEN_GROWTH_MB')
            self.assertEqual(self.run_gate(old, run, run)[0], 3)

    def test_five_mib_growth_regression_fails(self):
        base, candidate = fixture(), fixture()
        base['PF']['POPULATED_OPEN_GROWTH_MB'] = [2] * 7
        candidate['PF']['POPULATED_OPEN_GROWTH_MB'] = [7] * 7
        code, output = self.run_gate(base, candidate, base)
        self.assertEqual(code, 1)
        self.assertIn('| PF_POPULATED_OPEN_GROWTH_MB | 2.000000000 | 2.000000000 | 0.000000000 | 7.000000000 | 7.000000000 | 6.750000000 | FAIL |', output)

    def test_exit_missing_or_unparsable(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(gate.main([]), 3)
        for text in ('', 'PF_REFERENCE_JSON=bad', log(fixture()).replace('1,1,1', 'nan,1,1', 1)):
            path = Path(self.directory.name) / 'bad'
            path.write_text(text)
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(gate.main(['--base', str(path), '--candidate', str(path)]), 3)
        incomplete = fixture()
        del incomplete['PF5']['EMPTY_TOGGLE_Q1_MS']
        self.assertEqual(self.run_gate(incomplete, fixture())[0], 3)

    def test_pooled_reference_arithmetic_upper_median(self):
        base, after, candidate = fixture(), fixture(), fixture()
        base['PF']['EMPTY_OPEN_MS'] = [1, 2, 4]
        after['PF']['EMPTY_OPEN_MS'] = [2, 3, 5]
        candidate['PF']['EMPTY_OPEN_MS'] = [8, 9, 20]
        code, output = self.run_gate(base, candidate, after)
        self.assertEqual(code, 0)  # Maximum is diagnostic, median equals bound.
        self.assertIn('| PF_EMPTY_OPEN_MS | 3.000000000 | 5.000000000 | 4.000000000 | 9.000000000 | 20.000000000 | 9.000000000 | PASS |', output)
        self.assertEqual(gate.median([1, 2, 3, 4]), 3)

    def test_size_delta_pooled_formula(self):
        base, after, candidate = fixture(), fixture(), fixture()
        base['PF']['EMPTY_SAVE_MS'] = [1, 2, 3]
        after['PF']['EMPTY_SAVE_MS'] = [2, 3, 4]
        base['PF']['POPULATED_SAVE_MS'] = [2, 3, 4]
        after['PF']['POPULATED_SAVE_MS'] = [3, 4, 5]
        candidate['PF']['EMPTY_SAVE_MS'] = [1, 1, 1]
        candidate['PF']['POPULATED_SAVE_MS'] = [8, 8, 8]
        code, output = self.run_gate(base, candidate, after)
        self.assertEqual(code, 0)
        self.assertIn('SIZE SAVE_MS candidate_delta=7.000000000 bound=7.000000000 result=PASS', output)

    def test_stalls_use_each_runs_own_median(self):
        base, candidate = fixture(), fixture()
        for q in range(1, 6):
            base['PF5'][f'EMPTY_TOGGLE_Q{q}_MS'] = [2] * 40
        base['PF5']['EMPTY_TOGGLE_Q1_MS'][0] = 10  # Strict >, not >=.
        candidate['PF5']['EMPTY_TOGGLE_Q1_MS'][:10] = [6] * 10
        code, output = self.run_gate(base, candidate)
        self.assertEqual(code, 1)
        self.assertIn('STALL EMPTY_TOGGLE reference=0/200 candidate=10/200', output)
        self.assertIn('STALL POOLED reference=0/2000 candidate=10/2000', output)

    def test_stall_median_is_upper_and_pooled_probability(self):
        # Averaging the middle pair would count 7 as a stall; upper median
        # makes its threshold 10. This locks the brief's median definition.
        self.assertEqual(gate.stalls([1, 1, 2, 7]), 0)
        base, after, candidate = fixture(), fixture(), fixture()
        candidate['PF5']['EMPTY_TOGGLE_Q1_MS'][:5] = [6] * 5
        code, output = self.run_gate(base, candidate, after)
        self.assertEqual(code, 0)
        self.assertIn('reference=0/400 candidate=5/200 p=0.333333333333', output)
        self.assertAlmostEqual(gate.binomial_tail(5, 5, 1 / 3), (1 / 3) ** 5)

    def test_no_cold_metrics_allowed_only_in_retro_mode(self):
        old = fixture()
        for key in gate.COLD_KEYS:
            del old['PF'][key]
        self.assertEqual(self.run_gate(old, old)[0], 0)
        self.assertEqual(self.run_gate(old, old, old)[0], 3)


if __name__ == '__main__':
    unittest.main()
