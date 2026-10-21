#!/usr/bin/env python3
"""OD-10 collection integrity and row-blocking regressions."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import pf_fresh_open_memory as fresh
import pf_paired_gate as gate
from test_pf_paired_gate import fixture, log


class FreshOpenMemoryTests(unittest.TestCase):
    def test_fallback_requires_a_failure_in_either_aa_direction(self):
        self.assertFalse(fresh.requires_fresh_samples([1, 2, 3], [1, 2, 3]))
        self.assertTrue(fresh.requires_fresh_samples([1] * 7, [2] * 7))
        self.assertTrue(fresh.requires_fresh_samples([2] * 7, [1] * 7))

    def test_single_process_output_is_required_and_finite(self):
        good = fresh.MARKER + json.dumps({'growth': -2.5, 'pid': 1}) + '\n'
        self.assertEqual(fresh.read_sample(good)['growth'], -2.5)
        for bad in ['', good + good, fresh.MARKER + '{"growth":NaN,"pid":1}',
                    fresh.MARKER + '{"growth":1,"pid":0}']:
            with self.assertRaises(ValueError):
                fresh.read_sample(bad)

    def test_seven_independent_samples_replace_only_the_memory_row_and_still_block(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = {}
            for role in ('base', 'candidate', 'base-after'):
                path = Path(temp) / (role + '.log')
                original = fixture()
                original['PF'][fresh.KEY] = [100] * 7
                values = [7] * 7 if role == 'candidate' else [2] * 7
                path.write_text(log(original) + ''.join(fresh.MARKER + json.dumps({'growth': v, 'pid': i + 1}) + '\n'
                                                      for i, v in enumerate(values)))
                parsed = gate.parse_log(path)
                self.assertEqual(parsed['PF'][fresh.KEY], values)
                self.assertEqual(parsed['PF']['EMPTY_OPEN_GROWTH_MB'], [1, 2, 3])
                paths[role] = path
            with contextlib.redirect_stdout(io.StringIO()):
                code = gate.main(['--base', str(paths['base']), '--candidate', str(paths['candidate']),
                                  '--base-after', str(paths['base-after'])])
            self.assertEqual(code, 1, 'fresh-process sampling must not loosen the existing memory bound')

    def test_partial_or_reused_process_samples_refuse_gate_input(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'samples.log'
            for pids in ([1, 2, 3], [1] * 7):
                path.write_text(log(fixture()) + ''.join(fresh.MARKER + json.dumps({'growth': 1, 'pid': pid}) + '\n'
                                                        for pid in pids))
                with self.assertRaisesRegex(ValueError, 'seven distinct'):
                    gate.parse_log(path)

    def test_partial_role_replacement_is_not_a_valid_paired_measurement(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = [Path(temp) / role for role in ('base', 'candidate', 'after')]
            for path in paths:
                path.write_text(log(fixture()))
            with paths[1].open('a') as output:
                for pid in range(1, 8):
                    output.write(fresh.MARKER + json.dumps({'growth': 1, 'pid': pid}) + '\n')
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(gate.main(['--base', str(paths[0]), '--candidate', str(paths[1]),
                                           '--base-after', str(paths[2])]), 3)

    def test_complete_collection_uses_21_independent_locked_processes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            base, candidate, after = fixture(), fixture(), fixture()
            base['PF'][fresh.KEY] = [1] * 7
            after['PF'][fresh.KEY] = [10] * 7
            for role, data in [('base', base), ('candidate', candidate), ('base-after', after)]:
                (root / (role + '.log')).write_text(log(data))
            argv = []
            for role in ('base', 'candidate', 'base-after'):
                argv += ['--' + role, str(root / (role + '.log'))]
            for option in ('baseline-project', 'baseline-dd', 'candidate-project', 'candidate-dd', 'output-dir'):
                argv += ['--' + option, str(root / option)]
            calls = []
            def measure(command, **kwargs):
                calls.append(command)
                from types import SimpleNamespace
                return SimpleNamespace(returncode=0, stdout=fresh.MARKER + json.dumps({'growth': 2, 'pid': len(calls)}) + '\n')
            with patch.object(fresh.subprocess, 'run', side_effect=measure), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(fresh.main(argv), 0)
            self.assertEqual(len(calls), 21)
            self.assertTrue(all(command[0].endswith('xcodebuild-locked.sh') for command in calls))
            for role in ('base', 'candidate', 'base-after'):
                self.assertEqual(gate.parse_log(root / (role + '.log'))['PF'][fresh.KEY], [2] * 7)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate.main(['--base', str(root / 'base.log'), '--candidate', str(root / 'candidate.log'),
                                           '--base-after', str(root / 'base-after.log')]), 0)

    def test_failed_collection_cannot_install_partial_samples(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            base, candidate, after = fixture(), fixture(), fixture()
            base['PF'][fresh.KEY] = [1] * 7
            after['PF'][fresh.KEY] = [10] * 7
            for role, run in [('base', base), ('candidate', candidate), ('base-after', after)]:
                (root / (role + '.log')).write_text(log(run))
            argv = []
            for role in ('base', 'candidate', 'base-after'):
                argv += ['--' + role, str(root / (role + '.log'))]
            for option in ('baseline-project', 'baseline-dd', 'candidate-project', 'candidate-dd', 'output-dir'):
                argv += ['--' + option, str(root / option)]
            with patch.object(fresh.subprocess, 'run') as run, contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                run.return_value.returncode = 1
                run.return_value.stdout = 'measurement failed'
                self.assertEqual(fresh.main(argv), 1)
                command = run.call_args.args[0]
                self.assertTrue(command[0].endswith('xcodebuild-locked.sh'))
            for role in ('base', 'candidate', 'base-after'):
                self.assertNotIn(fresh.MARKER, (root / (role + '.log')).read_text())


if __name__ == '__main__':
    unittest.main()
