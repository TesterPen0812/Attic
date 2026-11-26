#!/usr/bin/env python3
"""The costs lane reuses a pinned reference build only when every input matches."""
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cost_build_reuse as reuse

ROOT = Path(__file__).resolve().parent.parent
TOOLCHAIN = b'Xcode 26.6\nBuild version 17A1\n26.4\n25E1\narm64\n'


def git(repo, *args):
    subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True)


class KeyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name) / 'ref'
        self.repo.mkdir()
        git(self.repo, 'init', '-q')
        git(self.repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'a')
        (self.repo / 'Fixture.swift').write_text('let a = 1\n')
        git(self.repo, 'add', 'Fixture.swift')
        git(self.repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'b')

    def tearDown(self):
        self.temp.cleanup()

    def key(self, name='baseline', flags='-O', toolchain=TOOLCHAIN):
        return reuse.build_key(name, self.repo, flags, toolchain)

    def test_same_inputs_give_the_same_key(self):
        self.assertEqual(self.key(), self.key())

    def test_every_input_changes_the_key(self):
        base = self.key()
        self.assertNotEqual(base, self.key(name='donebase'))
        self.assertNotEqual(base, self.key(flags='-O -DATTIC_COST_REFERENCE_HOST'))
        self.assertNotEqual(base, self.key(toolchain=TOOLCHAIN.replace(b'17A1', b'17A2')))
        (self.repo / 'Fixture.swift').write_text('let a = 2\n')  # overlay or prepare edit
        edited = self.key()
        self.assertNotEqual(base, edited)
        (self.repo / 'New.swift').write_text('let b = 1\n')  # untracked addition
        added = self.key()
        self.assertNotEqual(edited, added)
        (self.repo / 'New.swift').write_text('let b = 2\n')
        self.assertNotEqual(added, self.key())
        git(self.repo, 'checkout', '-q', '--', 'Fixture.swift')
        (self.repo / 'New.swift').unlink()
        self.assertEqual(base, self.key())
        git(self.repo, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'c')
        self.assertNotEqual(base, self.key())


class TrustTests(unittest.TestCase):
    REPO = 'owner/Attic'

    def run_info(self, **changes):
        info = {'path': '.github/workflows/macos-ci.yml', 'event': 'workflow_dispatch',
                'repository': {'full_name': self.REPO}, 'head_repository': {'full_name': self.REPO}}
        info.update(changes)
        return info

    def test_only_this_workflow_on_trusted_events_from_this_repository(self):
        self.assertTrue(reuse.trusted(self.run_info(), self.REPO))
        self.assertTrue(reuse.trusted(self.run_info(event='push'), self.REPO))
        self.assertFalse(reuse.trusted(self.run_info(event='pull_request'), self.REPO))
        self.assertFalse(reuse.trusted(self.run_info(event='pull_request_target'), self.REPO))
        self.assertFalse(reuse.trusted(self.run_info(path='.github/workflows/other.yml'), self.REPO))
        self.assertFalse(reuse.trusted(self.run_info(head_repository={'full_name': 'fork/Attic'}), self.REPO))
        self.assertFalse(reuse.trusted(self.run_info(head_repository=None), self.REPO))


class ArchiveTests(unittest.TestCase):
    def test_products_round_trip_keeps_symlinks_and_executable_bits(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'dd'
            products = source / 'Build/Products/Local'
            binary = products / 'Host.app/Contents/MacOS/Host'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/sh\n')
            binary.chmod(0o755)
            versions = products / 'Kit.framework/Versions'
            (versions / 'A').mkdir(parents=True)
            os.symlink('A', versions / 'Current')
            (source / 'Build/Products/Attic_Local.xctestrun').write_text('<plist/>')
            (source / 'Build/Intermediates.noindex').mkdir(parents=True)
            out = Path(temp) / 'out'
            with open(os.devnull, 'w') as quiet, unittest.mock.patch('sys.stdout', quiet):
                reuse.pack('baseline', source, out)
            archive = out / 'baseline-products.tar.gz'
            target = Path(temp) / 'restored'
            reuse.restore(archive, target)
            restored = target / 'Build/Products/Local'
            self.assertTrue(os.access(restored / 'Host.app/Contents/MacOS/Host', os.X_OK))
            self.assertEqual(os.readlink(restored / 'Kit.framework/Versions/Current'), 'A')
            self.assertFalse((target / 'Build/Intermediates.noindex').exists())
            self.assertFalse(archive.exists())

    def test_restore_refuses_members_outside_products(self):
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / 'evil').write_text('x')
            archive = Path(temp) / 'bad.tar.gz'
            subprocess.run(['tar', '-czf', str(archive), '-C', temp, 'evil'], check=True)
            with self.assertRaises(ValueError):
                reuse.restore(archive, Path(temp) / 'dd')

    def test_restore_requires_a_test_run_file(self):
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / 'dd/Build/Products').mkdir(parents=True)
            with open(os.devnull, 'w') as quiet, unittest.mock.patch('sys.stdout', quiet):
                reuse.pack('x', Path(temp) / 'dd', Path(temp) / 'out')
            with self.assertRaises(ValueError):
                reuse.restore(Path(temp) / 'out/x-products.tar.gz', Path(temp) / 'restored')


if __name__ == '__main__':
    unittest.main()
