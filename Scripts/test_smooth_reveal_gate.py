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

    def test_different_warmup_or_instrumentation_cannot_pass(self):
        settings = dict(mode='reveal', frame_monitor=False, settle_seconds=20,
                        idle_sample_seconds=60, allocations=False)
        before = {**self.sample(200), 'settings': settings}
        after = {**self.sample(20), 'settings': settings.copy()}
        self.assertTrue(compare([(before, after)] * 2)['passed'])
        for key, value in (('frame_monitor', True), ('settle_seconds', 2),
                           ('idle_sample_seconds', 0), ('allocations', True),
                           ('reveal_breakdown', True), ('sampled_reveal', True), ('reveal_counts', True)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                compare([(before, {**after, 'settings': {**settings, key: value}})] * 2)
        with self.assertRaises(ValueError):
            compare([(before, self.sample(20))] * 2)

    def test_count_instrumentation_cannot_establish_timing_acceptance(self):
        doc = {**self.sample(20), 'settings': {'reveal_counts': True}}
        with self.assertRaises(ValueError):
            compare([(doc, doc)] * 2)

    def test_requested_stage_instrumentation_must_have_been_recorded(self):
        doc = {**self.sample(20), 'settings': {'reveal_breakdown': True}}
        with self.assertRaises(ValueError):
            reveal(doc)
        doc['timings'] += [dict(name='RevealStage.' + name, milliseconds=1)
                           for name in ('BuildPages', 'PrepareGeometry', 'SetColdFrame',
                                        'OrderFront', 'Pointer', 'Animate')]
        self.assertEqual(reveal(doc), 20)
        doc['timings'][-1]['milliseconds'] = float('nan')
        with self.assertRaises(ValueError):
            reveal(doc)

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
