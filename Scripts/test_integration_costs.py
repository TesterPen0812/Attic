import json
import contextlib
import io
from pathlib import Path
import tempfile
import unittest

from check_integration_costs import METRICS, compare, main, rendered


class IntegrationCostsTests(unittest.TestCase):
    def write_cost_logs(self, root, reference, candidate, raw=None):
        for side, values in [('baseline', reference), ('candidate', candidate)]:
            for sample in (1, 2, 3):
                log = ''.join(f'ATTIC_INTEGRATION_COST {name} median_ms={values.get(name, [10]*3)[sample-1]}\n'
                              for name in METRICS)
                log += 'NOTE_RECOVERY_CONTROL_MAIN_ACTOR_MS_MEDIAN=0\n'
                if side == 'baseline':
                    log += ''.join(f'ATTIC_COST_SAMPLES metric={name} raw_ms={samples}\n'
                                   for name, samples in (raw or {}).items())
                    if sample == 1:
                        log += self.rendered_log(40)
                (root / f'integration-{side}-{sample}.log').write_text(log)
        (root / 'done-search.log').write_text(self.rendered_log(40))

    def test_every_notes_save_gate_uses_same_job_reference_range_and_raw_resolution(self):
        notes = {name for name in METRICS if name.startswith('note-')}
        self.assertEqual(len(notes), 10)  # standalone, empty/populated, with/without attachment; both paths
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for before, raw, accepted, rejected, bound in [
                ([40, 40, 40], [40, 41], 41, 42, 41.2),
                ([40, 42, 44], [40, 40.001, 44], 46, 47, 46.2),
                ([80, 80, 80], [80, 81], 81, 82, 81.2),
            ]:
                for value, expected in [(accepted, 0), (rejected, 1)]:
                    self.write_cost_logs(root, {name: before for name in notes},
                                         {name: [value]*3 for name in notes},
                                         {name: raw for name in notes})
                    with contextlib.redirect_stdout(io.StringIO()):
                        self.assertEqual(main(root), expected)
                    report = json.loads((root / 'integration-cost-comparison.json').read_text())
                    for name in notes:
                        self.assertAlmostEqual(report[name]['bound_ms'], bound)
                        self.assertEqual(report[name]['passed'], expected == 0)

    def test_notes_candidate_shift_and_outliers_cannot_widen_bound(self):
        notes = {name for name in METRICS if name.startswith('note-')}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_cost_logs(root, {name: [40]*3 for name in notes},
                                 {name: [41, 41, 499] for name in notes},
                                 {name: [40, 40, 40.001] for name in notes})
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(root), 1)
            report = json.loads((root / 'integration-cost-comparison.json').read_text())
            for name in notes:
                self.assertAlmostEqual(report[name]['bound_ms'], 40.201)
                self.assertFalse(report[name]['passed'])
            # A missing Notes measurement fails the real comparator, too.
            path = root / 'integration-candidate-2.log'
            path.write_text('\n'.join(line for line in path.read_text().splitlines()
                                      if not line.startswith('ATTIC_INTEGRATION_COST note-populated-save ')))
            with self.assertRaises(ValueError):
                main(root)

    def test_typical_sample_and_reference_spread_only(self):
        self.assertTrue(compare([30, 40, 84], [35, 40, 499])["passed"])
        self.assertFalse(compare([40, 40, 40], [41, 41, 499])["passed"])
        self.assertFalse(compare([40, 40, 40], [41, 41, 41])["passed"])
        self.assertTrue(compare([-2, -1, 0], [0, 0, 0])["passed"])
        with self.assertRaises(ValueError):
            compare([float('nan')], [1])

    def rendered_log(self, value):
        return ''.join(f'ATTIC_DONE_RESULTS run={s} frame_ms={value}\n' for s in range(3)) + ''.join(
            f'ATTIC_DONE_KEY key={key} raw_ms=[{value}, {value}, {value}]\n'
            for key in range(len('Finished task 12')))

    def test_missing_samples_and_runaway_cannot_hide(self):
        with self.assertRaises(ValueError):
            rendered(self.rendered_log(500))
        with self.assertRaises(ValueError):
            rendered(self.rendered_log(40).replace('run=2', 'run=1'))
        with self.assertRaises(ValueError):
            rendered(self.rendered_log(40).replace('[40, 40, 40]', '[40, 40]'))

    def test_complete_gate_and_missing_metric(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for side in ('baseline', 'candidate'):
                for sample in (1, 2, 3):
                    log = ''.join(f'ATTIC_INTEGRATION_COST {m} median_ms=40\n' for m in METRICS)
                    log += 'NOTE_RECOVERY_CONTROL_MAIN_ACTOR_MS_MEDIAN=0\n'
                    if side == 'baseline' and sample == 1:
                        log += self.rendered_log(40)
                    (root / f'integration-{side}-{sample}.log').write_text(log)
            (root / 'done-search.log').write_text(self.rendered_log(40))
            quantum = ''.join(f'ATTIC_COST_QUANTUM metric={name} quantum_ms=1\n'
                              for name in ['done-results-frame'] + [f'done-key-{key}' for key in range(len('Finished task 12'))])
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(root), 0)
                (root / 'done-search.log').write_text(self.rendered_log(41) + quantum)
                self.assertEqual(main(root), 0)
                (root / 'done-search.log').write_text(self.rendered_log(42) + quantum)
                self.assertEqual(main(root), 1)
            report = json.loads((root / 'integration-cost-comparison.json').read_text())
            self.assertFalse(report['done-results-frame']['passed'])
            self.assertEqual(report['done-results-frame']['resolution_ms'], 1)
            (root / 'integration-candidate-2.log').write_text('')
            with self.assertRaises(ValueError):
                main(root)

    def test_recovery_and_status_gate_chain_uses_three_block_medians(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            measured = {'status-toggle', 'recovery-main-actor', 'recovery-overhead'}
            for side in ('baseline', 'candidate'):
                for sample in (1, 2, 3):
                    values = {name: 40 for name in METRICS}
                    if side == 'candidate':
                        values.update({name: 499 if sample == 3 else 41 for name in measured})
                    log = ''.join(f'ATTIC_INTEGRATION_COST {name} median_ms={value}\n'
                                  for name, value in values.items())
                    log += 'NOTE_RECOVERY_CONTROL_MAIN_ACTOR_MS_MEDIAN=0\n'
                    if side == 'baseline' and sample == 1:
                        log += self.rendered_log(40)
                    if side == 'baseline':
                        log += ''.join(f'ATTIC_COST_SAMPLES metric={name} raw_ms=[40, 40, 41]\n'
                                       for name in measured)
                    (root / f'integration-{side}-{sample}.log').write_text(log)
            (root / 'done-search.log').write_text(self.rendered_log(40))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(root), 0)
                for sample in (1, 2):
                    path = root / f'integration-candidate-{sample}.log'
                    path.write_text(path.read_text().replace('median_ms=41', 'median_ms=42'))
                self.assertEqual(main(root), 1)
            report = json.loads((root / 'integration-cost-comparison.json').read_text())
            for name in measured:
                self.assertEqual(report[name]['bound_ms'], 41.4 if name == 'recovery-overhead' else 41.2)
                component = report[name]['components']['recovery-main-actor'] if name == 'recovery-overhead' else report[name]
                self.assertEqual(component['resolution_ms'], 1)
                self.assertFalse(report[name]['passed'])


if __name__ == '__main__':
    unittest.main()
