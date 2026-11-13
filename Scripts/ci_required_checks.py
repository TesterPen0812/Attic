#!/usr/bin/env python3
"""The final macOS gate uses raw step outcomes, including missing outcomes."""
import json
import os
from pathlib import Path
import sys

CHECKS = {
    'PROJECT_VERIFY': 'project-generation',
    'MAC_BUILD': 'mac-build',
    'STRICT_BUILD': 'strict-concurrency',
    'UNIT_TESTS': 'unit-tests',
    'DROPDOWN_TESTS': 'dropdown-timing',
    'FKA_TESTS': 'full-keyboard-access',
    'PERF_UI_TESTS': 'performance-ui-tests',
    'ANALYZER': 'analyzer',
    'FINAL_STATE': 'final-worktree',
}
# Timing gates are noisy on shared runners: in the fast lane they report but
# don't block (owner, 2026-10-19). Full, costs and pull-request runs still require them.
FULL_ONLY = {'FKA_TESTS', 'PERF_UI_TESTS', 'DROPDOWN_TESTS'}
PARALLEL_CHECKS = {
    'MACOS_JOB': 'macos',
    'ROUND_TRIPS': 'round-trips',
    'NOTES_SEEDS': 'notes-editor-seeds',
    'UNIT_CONTINUATION': 'unit-continuation',
}


def gate(env, checks=CHECKS):
    rows = []
    failures = []
    for key, name in checks.items():
        required = env.get('LANE') != 'fast' or key not in FULL_ONLY
        outcome = env.get(key) or 'missing'
        rows.append(f'| {name} | {outcome} | {"required" if required else "optional in fast"} |')
        print(f'{name:24} {outcome}')
        if required and outcome != 'success':
            failures.append(name)
            print(f'::error title=Required macOS check failed::{name}: {outcome}')
    summary = '# Required macOS checks\n\n| Check | Outcome | Scope |\n|---|---|---|\n'
    summary += '\n'.join(rows) + '\n\n'
    summary += ('Failed required checks: ' + ', '.join(failures) if failures else 'All required checks passed.') + '\n'
    if path := env.get('GITHUB_STEP_SUMMARY'):
        with Path(path).open('a') as stream:
            stream.write(summary)
    return int(bool(failures))


def summarize_tests(result, env):
    """Publish XCTest failures, including per-test timeouts, after any exit."""
    passed, failed, skipped = (result[key] for key in ('passedTests', 'failedTests', 'skippedTests'))
    lines = [
        '## XCTest results', '', '| Result | Tests |', '|---|---|',
        f'| Passed | {passed} |', f'| Failed | {failed} |', f'| Skipped | {skipped} |', '',
    ]
    print(f'XCTest: {passed} passed, {failed} failed, {skipped} skipped')
    for failure in result.get('testFailures', []):
        name = failure.get('testIdentifierString') or failure.get('testName') or 'Unknown test'
        message = failure.get('failureText', 'Test failed')
        details = message.replace('\n', ' ')
        lines.append(f'- `{name}`: {details}')
        annotation = f'{name}: {message}'.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
        print(f'::error title=XCTest failure::{annotation}')
    if path := env.get('GITHUB_STEP_SUMMARY'):
        with Path(path).open('a') as stream:
            stream.write('\n'.join(lines) + '\n')
    return int(failed > 0)


if __name__ == '__main__':
    if '--test-summary' in sys.argv:
        path = Path(sys.argv[sys.argv.index('--test-summary') + 1])
        sys.exit(summarize_tests(json.loads(path.read_text()), os.environ))
    sys.exit(gate(os.environ, PARALLEL_CHECKS if '--parallel' in sys.argv else CHECKS))
