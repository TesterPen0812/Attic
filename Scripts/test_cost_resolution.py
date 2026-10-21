"""OD-9 regression protection, independent of hosted performance timings."""
import unittest

from cost_resolution import compare, fixture_quantum, raw_samples


class CostResolutionTests(unittest.TestCase):
    def test_quantized_flat_samples_allow_one_step_not_two(self):
        # The synthetic timer is documented as integer milliseconds.
        one = compare([40, 40, 40], [41, 41, 41], quantum_ms=1)
        self.assertEqual(one['resolution_ms'], 1)
        self.assertEqual(one['bound_ms'], 41.2)
        self.assertTrue(one['passed'])
        self.assertFalse(compare([40, 40, 40], [42, 42, 42], quantum_ms=1)['passed'])

    def test_measured_quantized_step_and_two_step_regression(self):
        # The raw reference readings show the step even when each block's
        # median is 40. Never calibrate using the candidate's regression.
        raw = [40, 40, 41] * 3
        one = compare([40, 40, 40], [41, 41, 41], reference_samples=raw)
        self.assertEqual(one['resolution_ms'], 1)
        self.assertTrue(one['passed'])
        self.assertFalse(compare([40, 40, 40], [42, 42, 42], reference_samples=raw)['passed'])

    def test_constant_shift_cannot_invent_its_own_quantum(self):
        row = compare([40, 40, 40], [42, 42, 42])
        self.assertEqual(row['resolution_ms'], 0)
        self.assertFalse(row['passed'])

    def test_smallest_step_not_candidate_range_or_between_build_gap(self):
        row = compare([40, 40, 40], [40.1, 41, 499], reference_samples=[40, 40.9, 42])
        self.assertAlmostEqual(row['resolution_ms'], .9)
        self.assertTrue(row['passed'])
        self.assertFalse(compare([40, 40, 40], [40.1, 42, 499], quantum_ms=1)['passed'])
        self.assertFalse(compare([40, 40, 40], [41, 41, 499])['passed'])

    def test_recovery_and_status_use_medians_and_same_formula(self):
        for metric in ('status-toggle', 'recovery-main-actor', 'recovery-overhead'):
            with self.subTest(metric=metric):
                row = compare([10, 10, 10], [11, 11, 499], quantum_ms=1)
                self.assertTrue(row['passed'])
                self.assertEqual(row['bound_ms'], 11.2)
                self.assertFalse(compare([10, 10, 10], [10, 12, 12], quantum_ms=1)['passed'])
        row = compare([10, 11, 14], [15, 15, 499], quantum_ms=1)
        self.assertEqual(row['bound_ms'], 15.2)
        self.assertTrue(row['passed'])

    def test_signed_overhead_and_invalid_measurements(self):
        self.assertTrue(compare([-2, -1, 0], [0, 0, 0])['passed'])
        for samples in ([], [float('nan')], [float('inf')]):
            with self.assertRaises(ValueError):
                compare(samples, [1])
        for quantum in (0, -1, float('nan'), float('inf')):
            with self.assertRaises(ValueError):
                compare([1], [1], quantum)

    def test_fixture_metadata_rejects_inconsistent_quantum(self):
        text = 'ATTIC_COST_QUANTUM metric=done-results-frame quantum_ms=1\n'
        self.assertEqual(fixture_quantum([text], 'done-results-frame'), 1)
        self.assertIsNone(fixture_quantum([text], 'status-toggle'))
        with self.assertRaises(ValueError):
            fixture_quantum([text, text.replace('quantum_ms=1', 'quantum_ms=2')], 'done-results-frame')

    def test_raw_reference_samples_do_not_change_median_or_spread(self):
        text = 'ATTIC_COST_SAMPLES metric=status-toggle raw_ms=[40, 40, 41]\n'
        raw = raw_samples([text] * 3, 'status-toggle')
        row = compare([40, 40, 40], [41, 41, 41], reference_samples=raw)
        self.assertEqual(row['reference_range_ms'], 0)
        self.assertEqual(row['resolution_ms'], 1)
        self.assertEqual(row['bound_ms'], 41.2)
        self.assertTrue(row['passed'])


if __name__ == '__main__':
    unittest.main()
