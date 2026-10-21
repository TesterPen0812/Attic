#!/usr/bin/env python3
"""The final macOS gate uses raw step outcomes, including missing outcomes."""
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


if __name__ == '__main__':
    sys.exit(gate(os.environ, PARALLEL_CHECKS if '--parallel' in sys.argv else CHECKS))
