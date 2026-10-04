import json
from pathlib import Path
import tempfile
import unittest

from check_integration_costs import METRICS, compare, main, rendered


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
            self.assertEqual(main(root), 0)
            (root / 'done-search.log').write_text(self.rendered_log(41))
            self.assertEqual(main(root), 1)
            report = json.loads((root / 'integration-cost-comparison.json').read_text())
            self.assertFalse(report['done-results-frame']['passed'])
            (root / 'integration-candidate-2.log').write_text('')
            with self.assertRaises(ValueError):
                main(root)


if __name__ == '__main__':
    unittest.main()
