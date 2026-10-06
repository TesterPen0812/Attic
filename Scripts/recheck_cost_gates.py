#!/usr/bin/env python3
"""OD-15: accept once, reject only after a same-job interleaved re-check.

Re-run the fixture family containing a failing row, once. Shared fixtures emit
other rows too; those rows' first passes stay accepted. Bounds are computed by
the OD-8/9/17 comparators independently for each attempt. Missing data,
functional assertions, and candidate absolute budgets fail closed.
"""
import contextlib
from functools import partial
import io
import json
import os
from pathlib import Path
import shlex
import statistics
import subprocess
import sys

import check_cost_comparison as frame
import check_done_search_costs as done
import check_integration_costs as integration

ROOT = Path(__file__).resolve().parent.parent
FAMILIES = {
    'frame-row': (frame.main, 'cost-comparison.json'),
    'integration': (integration.main, 'integration-cost-comparison.json'),
    'integration-headless': (partial(integration.main, include_rendered=False), 'integration-cost-comparison.json'),
    'done-query': (done.main, 'done-search-comparison.json'),
}
INTEGRATION_TESTS = [
    'NotesPageControllerTests/testMeasuredMainActorSaveOnFiveThousandLineNote',
    'NotesPageControllerTests/testMeasuredMainActorSaveIsIndependentOfUnrelatedStoreContents',
    'NotesPageControllerTests/testCheckpointRetirementKeepsMainActorWithinSaveTolerance',
    'NoteSlice3bTests/testR9AccessibilityValidationStaysResponsiveWithStoredPayloadsAndActiveImport',
    'TaskPerformanceGateTests/testFamilySummaryPassAtSixThousandTasksIsMilliseconds',
    'TaskPerformanceGateTests/testStatusToggleAtSixThousandTasksStaysBounded',
    'TasksKeystrokeCostTests/testTheFirstKeystrokeCostsAboutWhatTheOthersDo',
]
RENDERED = 'DoneSearchCostTests/testRenderedFindKeystrokeMediansFitTheInputBudget'
QUERIES = ['DoneSearchCostTests/testMeasuresDoneSearchOn5000Tasks',
           'DoneSearchCostTests/testTheDiskBackedPhase5SeedAlsoFitsTheQueryBudget']


def flatten(report):
    if 'memory' in report:
        return {f'{fixture}:{query}': row for fixture, data in report.items()
                for query, row in data['queries'].items()}
    return report


def evaluate(directory, family):
    comparator, filename = FAMILIES[family]
    # Do not mistake stale JSON for evidence after a parsing/process failure.
    path = directory / filename
    path.unlink(missing_ok=True)
    with contextlib.redirect_stdout(io.StringIO()):
        result = comparator(directory)
    if result not in (0, 1) or not path.exists():
        raise ValueError(f'{family}: comparator did not produce complete evidence')
    return flatten(json.loads(path.read_text()))


def paired_order(sample):
    return ('candidate', 'baseline') if sample == 2 else ('baseline', 'candidate')


class Sampler:
    def __init__(self):
        self.temp = Path(os.environ['RUNNER_TEMP'])
        self.flags = shlex.split(os.environ['COST_FLAGS'])

    def run(self, directory, side, build, tests, filename):
        sources = {'baseline': 'AtticCostBaseline', 'integrationbase': 'AtticIntegrationCostReference',
                   'donebase': 'AtticDoneSearchBaseline'}
        source = ROOT if build == 'candidate' else self.temp / sources[build]
        env = dict(os.environ, TEST_RUNNER_ATTIC_COST_REFERENCE_ONLY='1' if side == 'baseline' else '0')
        log = directory / filename
        args = [str(ROOT / 'Scripts/xcodebuild_locked.sh'), 'test-without-building',
                '-project', 'Attic.xcodeproj', '-scheme', 'Attic', '-configuration', 'Local',
                '-destination', 'platform=macOS', '-derivedDataPath', str(self.temp / f'AtticCost-{build}'),
                '-resultBundlePath', str(log.with_suffix('.xcresult')), '-parallel-testing-enabled', 'NO']
        args += self.flags + [f'-only-testing:AtticTests/{test}' for test in tests]
        with log.open('w') as stream:
            result = subprocess.run(args, cwd=source, env=env, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f'{side} re-check exited {result.returncode}; see {log}')
        return log.read_text()

    def __call__(self, family, directory):
        directory.mkdir(parents=True)
        if family in ('frame-row', 'integration', 'integration-headless'):
            for sample in (1, 2, 3):
                for side in paired_order(sample):
                    if family == 'frame-row':
                        build = 'baseline' if side == 'baseline' else 'candidate'
                        tests = ['TasksFrameCostTests', 'TasksRowBuildCostTests']
                        filename = f'{side}-cost-{sample}.log'
                    else:
                        build = 'integrationbase' if side == 'baseline' else 'candidate'
                        tests = (INTEGRATION_TESTS[:-1] if family == 'integration-headless' else
                                 INTEGRATION_TESTS + ([RENDERED] if sample == 1 else []))
                        filename = f'integration-{side}-{sample}.log'
                    text = self.run(directory, side, build, tests, filename)
                    if family == 'integration' and side == 'candidate' and sample == 1:
                        (directory / 'done-search.log').write_text(text)
        else:
            # Historical disk fixture emits one session per invocation; the
            # current fixture emits three. Pick matching session i from each
            # paired invocation, keeping exactly three samples and the same
            # measurement boundaries. Archive complete raw logs as well.
            memory = {'baseline': [], 'candidate': []}
            candidate_disk = []
            for sample in (1, 2, 3):
                for side in paired_order(sample):
                    build = 'donebase' if side == 'baseline' else 'candidate'
                    text = self.run(directory, side, build, QUERIES, f'query-{side}-{sample}.log')
                    memory[side] += [line for line in text.splitlines()
                                     if line.startswith(f'ATTIC_DONE_SEARCH session={sample-1} ')]
                    disk = [line for line in text.splitlines() if line.startswith('ATTIC_PHASE5_DONE ')]
                    if side == 'baseline':
                        (directory / f'done-search-baseline-{sample}.log').write_text('\n'.join(disk) + '\n')
                    else:
                        candidate_disk += [line for line in disk
                                           if line.startswith(f'ATTIC_PHASE5_DONE session={sample-1} ')]
            path = directory / 'done-search-baseline-1.log'
            path.write_text(path.read_text() + '\n'.join(memory['baseline']) + '\n')
            (directory / 'done-search.log').write_text('\n'.join(memory['candidate'] + candidate_disk) + '\n')


def check(directory, sampler, families=None):
    evidence = {'policy': 'OD-15: one-step acceptance, two-step rejection', 'families': {}, 'errors': {}}
    for family in families or ('frame-row', 'integration', 'done-query'):
        rows = {}
        evidence['families'][family] = rows
        try:
            first = evaluate(directory, family)
            for name, row in first.items():
                rows[name] = dict(attempts=[row], passed=row['passed'])
            failed = {name for name, row in first.items() if not row['passed']}
            if failed:
                retry = directory / 'recheck' / family
                sampler(family, retry)
                second = evaluate(retry, family)
                if set(second) != set(first):
                    raise ValueError(f'{family}: re-check rows differ from first attempt')
                for name in failed:
                    rows[name]['attempts'].append(second[name])
                    rows[name]['passed'] = second[name]['passed']
        except (OSError, ValueError, RuntimeError, KeyError, StopIteration, TypeError) as error:
            evidence['errors'][family] = str(error)
    evidence['passed'] = not evidence['errors'] and all(
        row['passed'] for rows in evidence['families'].values() for row in rows.values())
    (directory / 'cost-gate-attempts.json').write_text(json.dumps(evidence, indent=2) + '\n')
    summary = ['## Cost comparison attempts (OD-15)', '',
               '| Family / row | Attempt | Reference median (ms) | Candidate median (ms) | Bound (ms) | Result |',
               '|---|---:|---:|---:|---:|---|']
    for family, rows in evidence['families'].items():
        for name, row in sorted(rows.items()):
            for index, attempt in enumerate(row['attempts'], 1):
                before = attempt.get('before_ms', attempt.get('baseline_ms'))
                after = attempt.get('after_ms', attempt.get('candidate_ms'))
                summary.append(f"| {family} / {name.replace('|', chr(92)+'|')} | {index} | "
                               f"{statistics.median(before):.3f} | {statistics.median(after):.3f} | "
                               f"{attempt['bound_ms']:.3f} | {'pass' if attempt['passed'] else 'fail'} |")
    for family, error in evidence['errors'].items():
        summary.append(f'\n**{family}: incomplete/failed evidence:** {error}')
    summary.append(f"\nFinal comparison result: **{'PASS' if evidence['passed'] else 'FAIL'}**. "
                   'Candidate absolute budgets and functional assertions gate independently.')
    rendered = '\n'.join(summary) + '\n'
    (directory / 'cost-gate-summary.md').write_text(rendered)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as stream:
            stream.write(rendered)
    print(rendered)
    return 0 if evidence['passed'] else 1


if __name__ == '__main__':
    sys.exit(check(Path(sys.argv[-1]), Sampler(), ['integration-headless'] if sys.argv[1] == '--headless-only' else None))
