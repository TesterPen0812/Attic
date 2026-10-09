#!/usr/bin/env python3
"""Authorization/argument gates; compatible seeded-store end-to-end runs are opt-in."""
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).with_name('migration-dry-run.zsh')


class MigrationDryRunAuthorizationTests(unittest.TestCase):
    def test_zsh_syntax(self):
        result = subprocess.run(['zsh', '-n', str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_requests_refuse_before_copying(self):
        # These paths are deliberately nonexistent, not paths to user data.
        cases = [
            [],
            ['--store-directory', '/explicitly-nonexistent-s6-fixture'],
            ['--fixture', '--source-quiescent', '--store-directory', '/explicitly-nonexistent-s6-fixture'],
            ['--approve-owner-store', '--store-directory', '/explicitly-nonexistent-s6-fixture'],
            ['--fixture', '--source-quiescent', '--store-directory', '/tmp/s6-fixture', '--store-name', '../escape'],
            ['--fixture', '--approve-owner-store', '--source-quiescent', '--store-directory', '/tmp/s6-fixture'],
        ]
        for args in cases:
            with self.subTest(args=args):
                result = subprocess.run([str(SCRIPT), *args], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn('Report directory:', result.stdout)


if __name__ == '__main__':
    unittest.main()
