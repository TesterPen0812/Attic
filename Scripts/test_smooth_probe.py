import unittest
from types import SimpleNamespace
from unittest.mock import patch

from smooth_probe import check_retention, wait_for_owned_exit


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


class SmoothTeardownTests(unittest.TestCase):
    def test_waits_for_only_the_owned_executable_to_exit(self):
        with patch('smooth_probe.subprocess.run', side_effect=[
                SimpleNamespace(stdout='/owned/preview\n'), SimpleNamespace(stdout='')]) as ps, \
                patch('smooth_probe.time.sleep') as sleep:
            wait_for_owned_exit(123, '/owned/preview')
            self.assertEqual(ps.call_count, 2)
            sleep.assert_called_once_with(0.1)
        with patch('smooth_probe.subprocess.run', return_value=SimpleNamespace(stdout='/another/process')):
            wait_for_owned_exit(123, '/owned/preview')

    def test_stalled_quit_fails_instead_of_force_quitting_anything(self):
        with self.assertRaises(TimeoutError):
            wait_for_owned_exit(123, '/owned/preview', timeout=0)


if __name__ == "__main__":
    unittest.main()
