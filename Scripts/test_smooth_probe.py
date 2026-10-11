import unittest

from smooth_probe import check_retention


class SmoothRetentionGateTests(unittest.TestCase):
    def records(self):
        return [dict(phase=f"smooth_visit_{n}", engines=min(n, 8), layouts=1, tasks=n)
                for n in range(1, 61)]

    def test_complete_bounded_workload_passes(self):
        check_retention(self.records())

    def test_missing_duplicate_and_out_of_order_visits_fail(self):
        records = self.records()
        for bad in (records[:-1], records + [records[-1]], list(reversed(records))):
            with self.assertRaises(ValueError):
                check_retention(bad)

    def test_retained_engine_or_layout_and_incomplete_task_fail(self):
        for field, value in (("engines", 9), ("engines", 0), ("layouts", 2), ("layouts", 0), ("tasks", 59)):
            records = self.records()
            records[-1][field] = value
            with self.assertRaises(ValueError):
                check_retention(records)


if __name__ == "__main__":
    unittest.main()
