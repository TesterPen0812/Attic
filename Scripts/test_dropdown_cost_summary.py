import unittest
from summarize_dropdown_costs import evidence_lines


class DropdownCostSummaryTests(unittest.TestCase):
    def test_nested_console_keeps_raw_attempts_and_pooled_decision(self):
        raw = 'DROPDOWN_COST_EVIDENCE_AX priorityOpen attempt=1 ratios=[0.6] ; attempt=2 ratios=[0.4] decision_samples=[0.6, 0.4] pooled=true statistic=0.5 unchanged_limit=0.501'
        log = {'subsections': [{'content': 'unrelated output\n' + raw + '\n'}]}
        self.assertEqual(list(evidence_lines(log)), [raw])
        self.assertEqual(list(evidence_lines({'content': 'no cost evidence'})), [])


if __name__ == '__main__':
    unittest.main()
