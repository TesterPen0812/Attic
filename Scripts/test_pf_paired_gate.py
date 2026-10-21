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

    def paired_history(self, attempts):
        roots = []
        for index, (base, candidate, after) in enumerate(attempts):
            root = Path(self.directory.name) / f'run-{index}'
            root.mkdir(exist_ok=True)
            for name, run in [('pf-base.log', base), ('pf-candidate.log', candidate), ('pf-base-after.log', after)]:
                (root / name).write_text(log(run))
            roots.append(root)
        args = ['--base', str(roots[-1] / 'pf-base.log'), '--candidate', str(roots[-1] / 'pf-candidate.log'),
                '--base-after', str(roots[-1] / 'pf-base-after.log')]
        for root in roots[:-1]:
            args += ['--prior-run', str(root)]
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            code = gate.main(args)
        return code, output.getvalue()

    def test_signed_growth_preserves_bound_arithmetic(self):
        base, candidate = fixture(), fixture()
        for run in (base, candidate):
            run['PF']['EMPTY_OPEN_GROWTH_MB'] = [-25, -24, -23]
        candidate['PF']['EMPTY_OPEN_GROWTH_MB'] = [-21] * 3
        code, output = self.run_gate(base, candidate, base)
        self.assertEqual(code, 0)
        self.assertIn('| -24.000000000 | -23.000000000 | 2.000000000 | -21.000000000 | -21.000000000 | -21.000000000 | PASS |', output)
        candidate['PF']['EMPTY_OPEN_GROWTH_MB'] = [-20.999] * 3
        self.assertEqual(self.run_gate(base, candidate, base)[0], 1)

    def test_one_unmeasurable_row_does_not_hide_valid_failure(self):
        after, candidate = fixture(), fixture()
        after['PF1']['EMPTY_AUTOSAVE_5000_MS'] = [6] * 3
        code, output = self.run_gate(fixture(), candidate, after)
        self.assertEqual(code, 2)
        self.assertIn('| PF1_EMPTY_AUTOSAVE_5000_MS | no | yes | — | — |', output)
        self.assertIn('CARRIED ROWS: PF1_EMPTY_AUTOSAVE_5000_MS', output)
        candidate['PF']['EMPTY_OPEN_MS'] = [6] * 3
        code, output = self.run_gate(fixture(), candidate, after)
        self.assertEqual(code, 1)
        self.assertIn('| PF_EMPTY_OPEN_MS | yes | no | — | yes |', output)

    def test_carry_forward_later_pass(self):
        after = fixture()
        after['PF1']['EMPTY_AUTOSAVE_5000_MS'] = [6] * 3
        # The current run cannot remeasure a formerly passed row. Its evidence
        # must survive, while the formerly unmeasurable row is now judged.
        next_after = fixture()
        next_after['PF']['EMPTY_OPEN_MS'] = [6] * 3
        code, output = self.paired_history([(fixture(), fixture(), after), (fixture(), fixture(), next_after)])
        self.assertEqual(code, 0)
        self.assertIn('CARRIED ROWS: PF1_EMPTY_AUTOSAVE_5000_MS', output)
        self.assertIn('CARRIED ROWS: none', output)

    def test_carry_forward_later_failure(self):
        after, candidate = fixture(), fixture()
        after['PF1']['EMPTY_AUTOSAVE_5000_MS'] = [6] * 3
        candidate['PF1']['EMPTY_AUTOSAVE_5000_MS'] = [6] * 3
        code, output = self.paired_history([(fixture(), candidate, after), (fixture(), candidate, fixture())])
        self.assertEqual(code, 1)
        self.assertIn('FAILED ROWS: PF1_EMPTY_AUTOSAVE_5000_MS', output)

    def test_valid_failure_is_sticky_even_after_a_pass(self):
        candidate = fixture()
        candidate['PF']['EMPTY_OPEN_MS'] = [6] * 3
        self.assertEqual(self.paired_history([(fixture(), candidate, fixture()), (fixture(), fixture(), fixture())])[0], 1)
        self.assertEqual(self.paired_history([(fixture(), fixture(), fixture()), (fixture(), candidate, fixture())])[0], 1)

    def test_all_rows_unmeasurable(self):
        base, after = fixture(), fixture()
        for group in ('PF', 'PF1'):
            for key in base[group]:
                base[group][key] = [1] * 3
                after[group][key] = [12 if key.startswith('POPULATED_') else 6] * 3
        for key in ('SIX_THOUSAND_TOGGLE_MS', 'POPULATED_TOGGLE_MS'):
            after['PF'][key] = [121] * 3
        for key in after['PF5']:
            after['PF5'][key] = [2] * 32 + [12] * 8
        with contextlib.redirect_stdout(io.StringIO()):
            rows = gate.evaluate(base, [base], 'test')
        candidate = fixture()
        for key in ('SIX_THOUSAND_TOGGLE_MS', 'POPULATED_TOGGLE_MS'):
            candidate['PF'][key] = [1, 2, 121]
        code, output = self.run_gate(base, candidate, after)
        self.assertEqual(code, 2)
        self.assertIn(f'judged=0 unmeasurable={len(rows)} pass=0 fail=0', output)
        self.assertIn('FAILED ROWS: none', output)

    def test_ceiling_candidate_at_limit_passes_regardless_of_bases(self):
        for key in ('SIX_THOUSAND_TOGGLE_MS', 'POPULATED_TOGGLE_MS'):
            for b, a in ((120, 120), (121, 120), (120, 121), (121, 121)):
                with self.subTest(key=key, base=b, after=a):
                    base, candidate, after = fixture(), fixture(), fixture()
                    base['PF'][key] = [1, 2, b]
                    after['PF'][key] = [1, 2, a]
                    candidate['PF'][key] = [1, 2, 120]
                    code, output = self.run_gate(base, candidate, after)
                    self.assertEqual(code, 0)
                    self.assertIn(f'CEILING {key} maximum=120.000000000 limit=120 result=PASS', output)
                    self.assertIn(f'| CEILING_{key} | yes | no | yes | — |', output)
                    for role, maximum in (('B', b), ('B′', a)):
                        status = 'PASS' if maximum <= 120 else 'FAIL'
                        self.assertIn(f'BASE CEILING {key} role={role} maximum={maximum:.9f} limit=120 result={status} (diagnostic)', output)

    def test_ceiling_candidate_breach_with_either_base_over_is_carried(self):
        for key in ('SIX_THOUSAND_TOGGLE_MS', 'POPULATED_TOGGLE_MS'):
            for b, a in ((121, 120), (120, 121), (121, 121)):
                with self.subTest(key=key, base=b, after=a):
                    base, candidate, after = fixture(), fixture(), fixture()
                    base['PF'][key] = [1, 2, b]
                    after['PF'][key] = [1, 2, a]
                    candidate['PF'][key] = [1, 2, 120.001]
                    code, output = self.run_gate(base, candidate, after)
                    self.assertEqual(code, 2)
                    self.assertIn(f'| CEILING_{key} | no | yes | — | — |', output)
                    self.assertIn(f'CARRIED ROWS: CEILING_{key}', output)
                    self.assertIn('FAILED ROWS: none', output)

    def test_ceiling_candidate_breach_with_both_bases_at_limit_fails(self):
        for key in ('SIX_THOUSAND_TOGGLE_MS', 'POPULATED_TOGGLE_MS'):
            with self.subTest(key=key):
                base, candidate = fixture(), fixture()
                base['PF'][key] = [1, 2, 120]
                candidate['PF'][key] = [1, 2, 120.001]
                code, output = self.run_gate(base, candidate, base)
                self.assertEqual(code, 1)
                self.assertIn(f'| CEILING_{key} | yes | no | — | yes |', output)
                self.assertIn(f'FAILED ROWS: CEILING_{key}', output)

    def test_ceiling_carry_forward_and_sticky_failure(self):
        for key in ('SIX_THOUSAND_TOGGLE_MS', 'POPULATED_TOGGLE_MS'):
            with self.subTest(key=key):
                base, over, passing = fixture(), fixture(), fixture()
                base['PF'][key] = [1, 2, 120]
                over['PF'][key] = [1, 2, 121]
                passing['PF'][key] = [1, 2, 120]
                unmeasurable = (over, over, base)
                passed = (over, passing, base)
                failed = (base, over, base)
                self.assertEqual(self.paired_history([unmeasurable, passed])[0], 0)
                self.assertEqual(self.paired_history([unmeasurable, failed])[0], 1)
                self.assertEqual(self.paired_history([failed, passed])[0], 1)
                self.assertEqual(self.paired_history([passed, failed])[0], 1)

    def test_carry_forward_budget_and_bad_history_are_input_errors(self):
        self.assertEqual(self.paired_history([(fixture(), fixture(), fixture())] * 4)[0], 3)

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

    def test_exit_unmeasurable_bidirectional(self):
        after = fixture()
        after['PF1']['EMPTY_AUTOSAVE_5000_MS'] = [6, 6, 6]
        self.assertEqual(self.run_gate(fixture(), fixture(), after)[0], 2)
        self.assertEqual(self.run_gate(after, fixture(), fixture())[0], 2)
        base = fixture()
        base['PF']['SIX_THOUSAND_TOGGLE_MS'] = [1, 2, 121]
        self.assertEqual(self.run_gate(base, fixture(), base)[0], 0)

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
