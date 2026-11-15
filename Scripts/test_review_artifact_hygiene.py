"""Keep one-off review capture hooks out of the hosted Composer tests."""
from pathlib import Path
import unittest


class ReviewArtifactHygieneTests(unittest.TestCase):
    def test_composer_has_no_review_capture_scaffolding(self):
        source = (Path(__file__).resolve().parent.parent / 'AtticTests/ComposerTests.swift').read_text()
        for marker in ('REVIEW_HOST_PID', 'ATTIC_REVIEW_RENDER', 'DNMReviewRenders',
                       'renderPendingComposerIfRequested'):
            with self.subTest(marker=marker):
                self.assertFalse(marker in source, f'review-only capture hook remains: {marker}')


if __name__ == '__main__':
    unittest.main()
