#!/usr/bin/env python3
"""Same-runner PF median, size and stall gate. Standard library only."""
import argparse
import json
import math
from pathlib import Path
import re
import sys

FIXTURES = ('EMPTY', 'POPULATED')
OPERATIONS = ('TOGGLE', 'RENAME', 'LINK_PAIR', 'SMALL_AUTOSAVE', 'BIG_AUTOSAVE')
PF_KEYS = {'SIX_THOUSAND_TOGGLE_MS'} | {
    f'{fixture}_{metric}' for fixture in FIXTURES
    for metric in ('OPEN_MS', 'OPEN_PEAK_MB', 'TOGGLE_MS', 'LINK_MS', 'SAVE_MS')
}
COLD_KEYS = {f'{fixture}_COLD_{operation}_MS' for fixture in FIXTURES
             for operation in ('TOGGLE', 'LINK', 'SAVE')}
PF1_KEYS = {f'{fixture}_{metric}_5000_MS' for fixture in FIXTURES
            for metric in ('AUTOSAVE', 'PREPARED_COMMIT')}
PF5_KEYS = {f'{fixture}_{operation}_Q{q}_MS' for fixture in FIXTURES
            for operation in OPERATIONS for q in range(1, 6)}


def median(values):
    return sorted(values)[len(values) // 2]


def spread(values):
    return max(values) - min(values)


def bound(values):
    return max(values) + spread(values)


def binomial_tail(c, total, p):
    """Exact binomial model, summed in log space to avoid overflow."""
    if c == 0:
        return 1.0
    terms = [math.log(math.comb(total, x)) + x * math.log(p)
             + (total - x) * math.log1p(-p) for x in range(c, total + 1)]
    largest = max(terms)
    return min(1.0, math.exp(largest) * math.fsum(math.exp(t - largest) for t in terms))


def validated(values):
    if not isinstance(values, list) or not values:
        raise ValueError('missing sample array')
    if any(isinstance(v, bool) or not isinstance(v, (int, float))
           or not math.isfinite(v) or v < 0 for v in values):
        raise ValueError('invalid sample')
    return values


def parse_log(path):
    """Markers can follow raw output or GitHub's job/step/timestamp prefix."""
    found = {}
    raw_pf5 = {}
    for line in Path(path).read_text().splitlines():
        match = re.search(r'\b(PF|PF1)_REFERENCE_JSON=(.*)', line)
        if match:
            # Parse only the last copy, including when an earlier copy is bad.
            found[match[1]] = match[2]
        match = re.search(r'\bPF5_SAMPLES_([A-Z0-9_]+)=(.*)', line)
        if match:
            raw_pf5[match[1]] = match[2]
    result = {}
    for name, required in (('PF', PF_KEYS), ('PF1', PF1_KEYS)):
        payload = json.loads(found[name])
        if not isinstance(payload, dict) or not required <= payload.keys():
            raise ValueError(f'{name}: missing metrics')
        values = {key: validated(sample['values']) for key, sample in payload.items()}
        if name == 'PF' and values.keys() & COLD_KEYS and not COLD_KEYS <= values.keys():
            raise ValueError('incomplete cold metrics')
        result[name] = values
    if set(raw_pf5) != PF5_KEYS:
        raise ValueError('missing PF5 quintiles')
    result['PF5'] = {key: validated([float(v) for v in raw.split(',')])
                     for key, raw in raw_pf5.items()}
    if any(len(v) != 40 for v in result['PF5'].values()):
        raise ValueError('PF5 quintile must contain 40 samples')
    return result


def series(run, fixture, operation):
    return [value for q in range(1, 6)
            for value in run['PF5'][f'{fixture}_{operation}_Q{q}_MS']]


def stalls(values):
    return sum(value > 5 * median(values) for value in values)


def evaluate(candidate, references, label):
    failed = False
    print(f'\n{label}')
    print('| Metric | Reference median | Reference maximum | Reference spread | Candidate median | Candidate maximum | Bound | Result |')
    print('| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |')
    for group in ('PF', 'PF1', 'PF5'):
        for key, actual in sorted(candidate[group].items()):
            pooled = [v for ref in references for v in ref[group][key]]
            passed = median(actual) <= bound(pooled)
            failed |= not passed
            numbers = (median(pooled), max(pooled), spread(pooled), median(actual), max(actual), bound(pooled))
            print(f'| {group}_{key} | ' + ' | '.join(f'{v:.9f}' for v in numbers)
                  + f' | {"PASS" if passed else "FAIL"} |')
    for metric in ('SAVE_MS', 'TOGGLE_MS', 'LINK_MS'):
        empty = [v for ref in references for v in ref['PF'][f'EMPTY_{metric}']]
        full = [v for ref in references for v in ref['PF'][f'POPULATED_{metric}']]
        delta = median(candidate['PF'][f'POPULATED_{metric}']) - median(candidate['PF'][f'EMPTY_{metric}'])
        limit = max(full) - min(empty) + max(spread(full), spread(empty))
        passed = delta <= limit
        failed |= not passed
        print(f'SIZE {metric} candidate_delta={delta:.9f} bound={limit:.9f} result={"PASS" if passed else "FAIL"}')
    pooled_c = pooled_r = 0
    p = 1 / (1 + len(references))
    for fixture in FIXTURES:
        for operation in OPERATIONS:
            c = stalls(series(candidate, fixture, operation))
            r = sum(stalls(series(ref, fixture, operation)) for ref in references)
            pooled_c += c
            pooled_r += r
            tail = binomial_tail(c, c + r, p)
            passed = tail >= 0.001
            failed |= not passed
            print(f'STALL {fixture}_{operation} reference={r}/{200 * len(references)} candidate={c}/200 p={p:.12g} p_value={tail:.12g} result={"PASS" if passed else "FAIL"}')
    tail = binomial_tail(pooled_c, pooled_c + pooled_r, p)
    passed = tail >= 0.001
    failed |= not passed
    print(f'STALL POOLED reference={pooled_r}/{2000 * len(references)} candidate={pooled_c}/2000 p={p:.12g} p_value={tail:.12g} result={"PASS" if passed else "FAIL"}')
    return not failed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True)
    parser.add_argument('--candidate', required=True)
    parser.add_argument('--base-after')
    try:
        args = parser.parse_args(argv)
    except SystemExit as error:
        return 0 if error.code == 0 else 3
    try:
        base = parse_log(args.base)
        candidate = parse_log(args.candidate)
        after = parse_log(args.base_after) if args.base_after else None
        runs = [base, candidate] + ([after] if after else [])
        if any(run[group].keys() != base[group].keys()
               for run in runs for group in base):
            raise ValueError('runs have different metric sets')
        if after and not COLD_KEYS <= base['PF'].keys():
            raise ValueError('three-run gate requires cold metrics')
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'INPUT ERROR: {error}', file=sys.stderr)
        return 3
    valid = True
    if after:
        valid = evaluate(after, [base], 'A/A B\u2032 against B')
        valid &= evaluate(base, [after], 'A/A B against B\u2032')
        for name, run in (('B', base), ('B\u2032', after)):
            for key in ('SIX_THOUSAND_TOGGLE_MS', 'POPULATED_TOGGLE_MS'):
                maximum = max(run['PF'][key])
                passed = maximum <= 120
                valid &= passed
                print(f'BASE CEILING {name} {key} maximum={maximum:.9f} limit=120 result={"PASS" if passed else "FAIL"}')
        print(f'A/A VERDICT: {"VALID" if valid else "UNMEASURABLE"}')
    else:
        print('A/A VERDICT: SKIPPED (single reference retro-check)')
    passed = evaluate(candidate, [base] + ([after] if after else []), 'Candidate against pooled reference')
    code = 2 if not valid else (0 if passed else 1)
    print(f'GATE: {("PASS", "CANDIDATE FAILURE", "UNMEASURABLE")[code]} exit={code}')
    return code


if __name__ == '__main__':
    sys.exit(main())
