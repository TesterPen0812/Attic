#!/usr/bin/env python3
"""Authorization/argument gates; compatible seeded-store end-to-end runs are opt-in."""
from pathlib import Path
from contextlib import closing
import json
import io
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from migration_copy import cleanup, filter_log, finalize, inventory, prepare, rows_snapshot

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


class MigrationCopyIntegrityTests(unittest.TestCase):
    def test_runtime_diagnostics_cannot_leak_row_values_to_retained_log(self):
        text = "Private fixture title\nCoreData: row { body = private fixture text; }\n** TEST SUCCEEDED **\n"
        output = io.StringIO()
        filter_log(io.StringIO(text), output)
        self.assertEqual(output.getvalue(), '** TEST SUCCEEDED **\n')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='AtticS6CopyTest.')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.out = self.root / 'out'
        self.out.mkdir()
        with closing(sqlite3.connect(self.source / 'development.store')) as db, db:
            db.execute('pragma journal_mode=wal')
            db.execute('create table ZNOTEITEM (Z_PK integer primary key, Z_ENT integer, Z_OPT integer, ZID blob, ZBODY text)')
            db.executemany('insert into ZNOTEITEM values (?,1,1,?,?)', [(1, b'ID', 'fixture'), (2, b'ID', 'fixture')])
        # Verify whole-directory copying, including external storage.
        support = self.source / '.development_SUPPORT'
        support.mkdir()
        (support / 'fixture-blob').write_bytes(b'fixture bytes')

    def prepare(self):
        prepare(self.source, 'development.store', self.out, 'fixture', Path(__file__).parents[1])

    def test_writable_copy_preserves_source_and_duplicate_rows_and_is_removed(self):
        before = inventory(self.source)
        self.prepare()
        copy = self.out / 'copy' / 'development.store'
        with closing(sqlite3.connect(copy)) as db, db:
            db.execute('alter table ZNOTEITEM add column ZCONTENTFORMAT integer default 0')
        report = {'status': 'opened', 'noteRows': 2, 'rows': [
            {'state': 'verified-migration-candidate', 'reason': None}]}
        (self.out / 'migration-report.json').write_text(json.dumps(report))
        finalize(self.source, 'development.store', self.out, 0)
        self.assertEqual(inventory(self.source), before)
        self.assertFalse((self.out / 'copy').exists())
        self.assertFalse((self.out / 'before.json').exists())
        self.assertFalse((self.out / 'rows-before.json').exists())
        self.assertTrue(json.loads((self.out / 'integrity-report.json').read_text())['legacy_rows_unchanged'])

    def test_deleting_a_physical_replica_is_detected(self):
        self.prepare()
        original = json.loads((self.out / 'rows-before.json').read_text())
        copy = self.out / 'copy' / 'development.store'
        with closing(sqlite3.connect(copy)) as db, db:
            db.execute('delete from ZNOTEITEM where Z_PK=2')
        self.assertNotEqual(rows_snapshot(copy, original), original)
        cleanup(self.out)

    def test_symlinks_are_refused_before_copying(self):
        (self.source / 'link').symlink_to(self.root)
        with self.assertRaisesRegex(RuntimeError, 'Symlink'):
            self.prepare()
        self.assertFalse((self.out / 'copy').exists())

    def test_protected_containers_are_refused_without_reading_them(self):
        for bundle in ('com.taha.Attic', 'com.emanueledipietro.Attic'):
            protected = Path.home() / 'Library' / 'Containers' / bundle
            with patch.object(Path, 'resolve', side_effect=AssertionError('No protected path resolution allowed')):
                with self.assertRaisesRegex(RuntimeError, 'Protected'):
                    prepare(protected, 'development.store', self.out, 'owner', self.root)
            self.assertFalse((self.out / 'copy').exists())

    def test_runner_failure_has_unknown_counts_and_still_cleans_copy(self):
        before = inventory(self.source)
        self.prepare()
        with self.assertRaisesRegex(RuntimeError, 'did not complete'):
            finalize(self.source, 'development.store', self.out, 65)
        self.assertEqual(inventory(self.source), before)
        self.assertFalse((self.out / 'copy').exists())
        self.assertIsNone(json.loads((self.out / 'migration-report.json').read_text())['counts'])
        self.assertTrue(json.loads((self.out / 'integrity-report.json').read_text())['source_unchanged'])

    def test_unreadable_copy_still_publishes_source_check_and_cleans_copy(self):
        self.prepare()
        (self.out / 'copy' / 'development.store').write_bytes(b'not a database')
        with self.assertRaisesRegex(RuntimeError, 'finalization failed'):
            finalize(self.source, 'development.store', self.out, 65)
        report = json.loads((self.out / 'integrity-report.json').read_text())
        self.assertTrue(report['source_unchanged'])
        self.assertIsNone(report['legacy_rows_unchanged'])
        self.assertTrue(report['working_copy_deleted'])


if __name__ == '__main__':
    unittest.main()
