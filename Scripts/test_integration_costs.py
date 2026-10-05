import json
import contextlib
import io
from pathlib import Path
import tempfile
import unittest

from check_integration_costs import METRICS, compare, done_only, main, rendered


class IntegrationCostsTests(unittest.TestCase):
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

    def test_phase3_done_gate_retains_bounds_and_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'done-results-reference.log').write_text(self.rendered_log(40))
            candidate = root / 'foundation.log'
            with contextlib.redirect_stdout(io.StringIO()):
                candidate.write_text(self.rendered_log(40))
                self.assertEqual(done_only(root), 0)
                candidate.write_text(self.rendered_log(41))
                self.assertEqual(done_only(root), 1)
                report = json.loads((root / 'done-results-comparison.json').read_text())
                self.assertEqual(report['done-results-frame']['bound_ms'], 40.2)
                candidate.write_text(self.rendered_log(40).replace('key=14', 'key=13'))
                with self.assertRaises(ValueError):
                    done_only(root)

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
                self.assertEqual(report[name]['bound_ms'], 41.2)
                self.assertEqual(report[name]['resolution_ms'], 1)
                self.assertFalse(report[name]['passed'])


if __name__ == '__main__':
    unittest.main()
