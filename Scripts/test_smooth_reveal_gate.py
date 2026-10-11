import unittest
from smooth_reveal_gate import compare, reveal


class SmoothRevealGateTests(unittest.TestCase):
    def sample(self, ms):
        return dict(bundle='com.taha.Attic.preview.phasex',
                    timings=[dict(name='PanelRevealToOrderedFront', milliseconds=ms)])

    def test_paired_difference_and_spread_are_reported(self):
        result = compare([(self.sample(40), self.sample(30)), (self.sample(20), self.sample(18))])
        self.assertTrue(result['passed'])
        self.assertEqual(result['median_paired_delta_ms'], -6)
        self.assertEqual(result['reference_spread_ms'], 20)
        self.assertEqual(result['candidate_spread_ms'], 12)

    def test_slower_candidate_fails_without_an_added_allowance(self):
        self.assertFalse(compare([(self.sample(20), self.sample(21))] * 2)['passed'])

    def test_missing_invalid_or_warm_data_cannot_pass(self):
        for value in (0, -1, float('inf'), float('nan')):
            with self.assertRaises(ValueError):
                reveal(self.sample(value))
        with self.assertRaises(ValueError):
            compare([(self.sample(20), self.sample(19))])
        doc = self.sample(20)
        doc['timings'] *= 2
        with self.assertRaises(ValueError):
            reveal(doc)


if __name__ == '__main__':
    unittest.main()
