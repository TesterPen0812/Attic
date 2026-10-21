#!/usr/bin/env python3
"""OD-15 for Phase 3 PF: one same-job B/C/B re-check, unchanged bounds.

A/A-unmeasurable rows are retried too, but cannot become judged failures.
Every raw comparison and sample is retained; candidate correctness/ceilings
and failed sampling processes gate independently. Exact-SHA carry remains.
"""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

import pf_paired_gate as gate

ROOT = Path(__file__).resolve().parent.parent
TESTS = ('testPFFoundationSizeAndProductionPaths',
         'testPF1LargeAutosaveAndPreparedCommitAgainstPairedBase',
         'testPF5InterleavedSessionSoakAgainstPairedBase')


def evaluate(directory):
    paths = [directory / name for name in ('pf-base.log', 'pf-candidate.log', 'pf-base-after.log')]
    # Reuse the production input checks too (complete metrics, cold rows,
    # matched fresh processes). A parsing failure is never timing evidence.
    output = io.StringIO()
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        code = gate.main(['--base', str(paths[0]), '--candidate', str(paths[1]), '--base-after', str(paths[2])])
    (directory / 'pf-comparison.txt').write_text(output.getvalue())
    if code not in (0, 1, 2):
        raise ValueError(output.getvalue())
    samples = [gate.parse_log(path) for path in paths]
    with contextlib.redirect_stdout(io.StringIO()):
        results, eligible = gate.evaluate_attempt(*samples)
    return {name: dict(passed=result, judged=name in eligible) for name, result in results.items()}


class Sampler:
    def __call__(self, directory):
        directory = directory.resolve()
        directory.mkdir(parents=True)
        temp = Path(os.environ['RUNNER_TEMP'])
        flags = shlex.split(os.environ['PF_COST_FLAGS'])
        # Fixture-by-fixture B/C/B rather than running whole reference blocks
        # apart. Each fixture retains exactly its existing samples and bounds.
        for test in TESTS:
            for role in ('base', 'candidate', 'base-after'):
                reference = role != 'candidate'
                source = temp / 'AtticPFBase' if reference else ROOT
                derived = temp / 'AtticPFBaseBuild' if reference else ROOT / '.build/dd'
                name = 'AtticP3PFBaseHost' if reference else 'AtticP3CrashHost'
                bundle = 'pfbase' if reference else 'crashhost'
                env = dict(os.environ, TEST_RUNNER_ATTIC_COST_REFERENCE_ONLY='1' if reference else '0')
                command = [str(ROOT / 'Scripts/xcodebuild-locked.sh'), 'test-without-building',
                           '-project', str(source / 'Attic.xcodeproj'), '-scheme', 'Attic', '-configuration', 'Local',
                           '-destination', 'platform=macOS', '-derivedDataPath', str(derived),
                           '-resultBundlePath', str(directory / f'{role}-{test}.xcresult'),
                           '-parallel-testing-enabled', 'NO',
                           f'ATTIC_MACOS_UNIT_HOST_PRODUCT_NAME={name}', f'ATTIC_MACOS_UNIT_HOST_EXECUTABLE_NAME={name}',
                           f'ATTIC_MACOS_UNIT_HOST_BUNDLE_IDENTIFIER=com.taha.Attic.p3.{bundle}']
                command += flags + [f'-only-testing:AtticTests/TaskPerformanceGateTests/{test}']
                with (directory / f'pf-{role}.log').open('a') as stream:
                    result = subprocess.run(command, cwd=source, env=env, stdout=stream, stderr=subprocess.STDOUT)
                if result.returncode:
                    raise RuntimeError(f'{role}/{test} exited {result.returncode}; sampling/correctness failure')
        subprocess.run([sys.executable, str(ROOT / 'Scripts/pf_fresh_open_memory.py'),
                        '--base', str(directory / 'pf-base.log'), '--candidate', str(directory / 'pf-candidate.log'),
                        '--base-after', str(directory / 'pf-base-after.log'),
                        '--baseline-project', str(temp / 'AtticPFBase/Attic.xcodeproj'),
                        '--baseline-dd', str(temp / 'AtticPFBaseBuild'), '--candidate-project', str(ROOT / 'Attic.xcodeproj'),
                        '--candidate-dd', str(ROOT / '.build/dd'), '--output-dir', str(directory / 'pf-fresh-open')], check=True)


def check(directory, sampler, prior=()):
    evidence = dict(policy='OD-15: one-step acceptance, two-step rejection; unchanged PF bounds', runs=[], errors=[])
    accepted, failed, all_rows = set(), set(), set()
    try:
        if len(prior) > 1:
            raise ValueError('Phase 3 permits at most two CI attempts at this SHA')
        for root in [*prior, directory]:
            first = evaluate(root)
            rows = {name: dict(attempts=[row], passed=row['passed'] if row['judged'] else None)
                    for name, row in first.items()}
            retry_names = {name for name, row in first.items() if not row['judged'] or not row['passed']}
            if retry_names:
                retry = root / 'pf-recheck'
                if root == directory:
                    sampler(retry)
                second = evaluate(retry)
                if set(second) != set(first):
                    raise ValueError('PF re-check rows differ from first attempt')
                for name in retry_names:
                    rows[name]['attempts'].append(second[name])
                    # A failure needs two judged failures. An invalid second
                    # reference remains unmeasurable, never a candidate pass.
                    rows[name]['passed'] = (True if second[name]['judged'] and second[name]['passed'] else
                                           False if first[name]['judged'] and second[name]['judged'] else None)
            if all_rows and all_rows != set(rows):
                raise ValueError('PF carried row sets differ')
            all_rows = set(rows)
            accepted.update(name for name, row in rows.items() if row['passed'] is True)
            failed.update(name for name, row in rows.items() if row['passed'] is False)
            evidence['runs'].append(dict(directory=str(root), rows=rows))
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        evidence['errors'].append(str(error))
    unmeasurable = all_rows - accepted - failed
    code = 3 if evidence['errors'] else 1 if failed else 2 if unmeasurable else 0
    evidence.update(exit=code, accepted=sorted(accepted), failed=sorted(failed), unmeasurable=sorted(unmeasurable))
    (directory / 'pf-gate-attempts.json').write_text(json.dumps(evidence, indent=2) + '\n')
    summary = f"OD-15 PF: accepted={len(accepted)} failed={len(failed)} unmeasurable={len(unmeasurable)} exit={code}\n"
    for error in evidence['errors']:
        summary += f'INPUT/SAMPLING ERROR: {error}\n'
    print(summary)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as stream:
            stream.write(summary)
    return code


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--prior-run', type=Path, action='append', default=[])
    args = parser.parse_args()
    sys.exit(check(args.directory, Sampler(), args.prior_run))
