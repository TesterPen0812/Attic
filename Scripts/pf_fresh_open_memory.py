#!/usr/bin/env python3
"""OD-10 fallback: remeasure only populated open growth after an A/A failure."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

import pf_paired_gate as gate

MARKER = 'PF_FRESH_OPEN_SAMPLE_JSON='
KEY = 'POPULATED_OPEN_GROWTH_MB'


def requires_fresh_samples(base, after):
    return (gate.median(after) > gate.bound(base)
            or gate.median(base) > gate.bound(after))


def read_sample(log):
    samples = [json.loads(match[1]) for match in re.finditer(r'\b' + MARKER + r'([^\n]+)', log)]
    if len(samples) != 1:
        raise ValueError('each fresh process must emit exactly one open-growth sample')
    sample = samples[0]
    gate.validated([sample['growth']])
    if not isinstance(sample['pid'], (int, float)) or sample['pid'] <= 0:
        raise ValueError('missing test-host process identity')
    return sample


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for role in ('base', 'candidate', 'base-after'):
        parser.add_argument('--' + role, required=True, type=Path)
    parser.add_argument('--baseline-project', required=True, type=Path)
    parser.add_argument('--baseline-dd', required=True, type=Path)
    parser.add_argument('--candidate-project', required=True, type=Path)
    parser.add_argument('--candidate-dd', required=True, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--wrapper', type=Path, default=Path(__file__).with_name('xcodebuild-locked.sh'))
    args = parser.parse_args(argv)
    try:
        base = gate.parse_log(args.base)['PF'][KEY]
        after = gate.parse_log(args.base_after)['PF'][KEY]
        if not requires_fresh_samples(base, after):
            print('OD-10: populated open growth passed A/A; original samples retained')
            return 0
        print('OD-10: populated open growth is A/A-unmeasurable; measuring fresh processes', flush=True)
        args.output_dir.mkdir(parents=True, exist_ok=True)
        roles = [('base', args.base), ('candidate', args.candidate), ('base-after', args.base_after)]
        collected = {role: [] for role, _ in roles}
        process_ids = set()
        for index in range(7):
            for role, _ in roles:
                candidate = role == 'candidate'
                host = 'AtticP3CrashHost' if candidate else 'AtticP3PFBaseHost'
                bundle = 'com.taha.Attic.p3.crashhost' if candidate else 'com.taha.Attic.p3.pfbase'
                project = args.candidate_project if candidate else args.baseline_project
                dd = args.candidate_dd if candidate else args.baseline_dd
                result = args.output_dir / f'{role}-{index + 1}.xcresult'
                command = [str(args.wrapper.resolve()), '-project', str(project.resolve()), '-scheme', 'Attic',
                           '-configuration', 'Local', '-destination', 'platform=macOS',
                           '-derivedDataPath', str(dd.resolve()), '-resultBundlePath', str(result.resolve()),
                           'ATTIC_MACOS_UNIT_HOST_PRODUCT_NAME=' + host,
                           'ATTIC_MACOS_UNIT_HOST_EXECUTABLE_NAME=' + host,
                           'ATTIC_MACOS_UNIT_HOST_BUNDLE_IDENTIFIER=' + bundle,
                           'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGNING_REQUIRED=YES', 'CODE_SIGN_STYLE=Manual',
                           'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=', 'ENABLE_DEBUG_DYLIB=NO',
                           '-parallel-testing-enabled', 'NO',
                           '-only-testing:AtticTests/TaskPerformanceGateTests/testPFPopulatedOpenGrowthFreshProcessSample',
                           'test-without-building']
                run = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                (args.output_dir / f'{role}-{index + 1}.log').write_text(run.stdout)
                if run.returncode:
                    raise ValueError(f'{role} sample {index + 1} failed with exit {run.returncode}; see {args.output_dir}')
                sample = read_sample(run.stdout)
                if sample['pid'] in process_ids:
                    raise ValueError('a test-host process was reused across fresh samples')
                process_ids.add(sample['pid'])
                collected[role].append(sample)
                print(f'OD-10 {role} sample={index + 1} pid={sample["pid"]} growth_mb={sample["growth"]}', flush=True)
        # Publish only complete matched sets. Partial or failed collection never
        # replaces the original blocking row; the gate still checks both A/A directions.
        for role, log in roles:
            with log.open('a') as output:
                output.write('\n' + '\n'.join(MARKER + json.dumps(sample) for sample in collected[role]) + '\n')
        print('OD-10: installed 21 independent samples; existing A/A and candidate bounds remain blocking')
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'OD-10 INPUT/MEASUREMENT ERROR: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
