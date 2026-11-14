"""Guards against review-only test scaffolding leaking global state or disk space."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ReviewTestHygiene(unittest.TestCase):
    def test_watched_calendar_fixture_uses_private_board(self):
        source = (ROOT / 'AtticTests/CalendarPageHostedTests.swift').read_text()
        fixture = source.split('func testReviewWatchedDaySavesOwnedEventBeforeSwitchingDays()', 1)[1].split('\n    func ', 1)[0]
        self.assertNotIn('AgentWatchBoard.shared', fixture, 'a test must not replace the process-wide watching binding')

    def test_review_capture_scaffolding_is_bounded(self):
        calendar = (ROOT / 'AtticTests/CalendarPageHostedTests.swift').read_text()
        fixture = calendar.split('func testReviewWatchedDaySavesOwnedEventBeforeSwitchingDays()', 1)[1].split('\n    func ', 1)[0]
        self.assertNotIn('.keepAlways', fixture, 'successful runs must not keep the large Calendar attachment')
        draw = (ROOT / 'AtticTests/Draw3PageTests.swift').read_text()
        self.assertNotIn('DRAW_REVIEW_CAPTURE_DIR', draw, 'the unused output-directory switch must not gate capture code')

if __name__ == '__main__':
    unittest.main()
