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
    for metric in ('OPEN_MS', 'OPEN_GROWTH_MB', 'TOGGLE_MS', 'LINK_MS', 'SAVE_MS')
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
           or not math.isfinite(v) for v in values):
        raise ValueError('invalid sample')
    return values


def parse_log(path):
    """Markers can follow raw output or GitHub's job/step/timestamp prefix."""
    found = {}
    raw_pf5 = {}
    fresh_open = []
    for line in Path(path).read_text().splitlines():
        match = re.search(r'\b(PF|PF1)_REFERENCE_JSON=(.*)', line)
        if match:
            # Parse only the last copy, including when an earlier copy is bad.
            found[match[1]] = match[2]
        match = re.search(r'\bPF5_SAMPLES_([A-Z0-9_]+)=(.*)', line)
        if match:
            raw_pf5[match[1]] = match[2]
        match = re.search(r'\bPF_FRESH_OPEN_SAMPLE_JSON=(.*)', line)
        if match:
            fresh_open.append(json.loads(match[1]))
    result = {}
    for name, required in (('PF', PF_KEYS), ('PF1', PF1_KEYS)):
        payload = json.loads(found[name])
        if not isinstance(payload, dict) or not required <= payload.keys():
            raise ValueError(f'{name}: missing metrics')
        values = {key: validated(sample['values']) for key, sample in payload.items()}
        if name == 'PF' and values.keys() & COLD_KEYS and not COLD_KEYS <= values.keys():
            raise ValueError('incomplete cold metrics')
        result[name] = values
    if fresh_open:
        if len(fresh_open) != 7 or len({sample['pid'] for sample in fresh_open}) != 7:
            raise ValueError('fresh open growth requires seven distinct test-host processes')
        result['PF']['POPULATED_OPEN_GROWTH_MB'] = validated([sample['growth'] for sample in fresh_open])
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


def evaluate(candidate, references, label, eligible=None):
    results = {}
    def verdict(row, passed):
        results[row] = passed
        if eligible is not None and row not in eligible:
            return 'UNMEASURABLE'
        return 'PASS' if passed else 'FAIL'

    print(f'\n{label}')
    print('| Metric | Reference median | Reference maximum | Reference spread | Candidate median | Candidate maximum | Bound | Result |')
    print('| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |')
    for group in ('PF', 'PF1', 'PF5'):
        for key, actual in sorted(candidate[group].items()):
            pooled = [v for ref in references for v in ref[group][key]]
            # Owner acceptance: /Users/taha/Developer/attic-redesign-assets/phase2/
            # owner-decisions.md, "Decisions, 2026-10-03 ~19:30" and OD-2
            # ("Orchestrator decisions (owner away, mandate 2026-10-04)").
            # Round 1c measured +4.703247 MiB for duplicate-safe guards.
            # Only the candidate pooled-reference populated-open growth gets this
            # accepted cost; A/A validity and every other bound stay unchanged.
            limit = bound(pooled) + (4.75 if group == 'PF' and key == 'POPULATED_OPEN_GROWTH_MB' and len(references) == 2 else 0)
            passed = median(actual) <= limit
            row = f'{group}_{key}'
            status = verdict(row, passed)
            numbers = (median(pooled), max(pooled), spread(pooled), median(actual), max(actual), limit)
            print(f'| {group}_{key} | ' + ' | '.join(f'{v:.9f}' for v in numbers)
                  + f' | {status} |')
    for metric in ('SAVE_MS', 'TOGGLE_MS', 'LINK_MS'):
        empty = [v for ref in references for v in ref['PF'][f'EMPTY_{metric}']]
        full = [v for ref in references for v in ref['PF'][f'POPULATED_{metric}']]
        delta = median(candidate['PF'][f'POPULATED_{metric}']) - median(candidate['PF'][f'EMPTY_{metric}'])
        limit = max(full) - min(empty) + max(spread(full), spread(empty))
        passed = delta <= limit
        status = verdict(f'SIZE_{metric}', passed)
        print(f'SIZE {metric} candidate_delta={delta:.9f} bound={limit:.9f} result={status}')
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
            status = verdict(f'STALL_{fixture}_{operation}', passed)
            print(f'STALL {fixture}_{operation} reference={r}/{200 * len(references)} candidate={c}/200 p={p:.12g} p_value={tail:.12g} result={status}')
    tail = binomial_tail(pooled_c, pooled_c + pooled_r, p)
    passed = tail >= 0.001
    status = verdict('STALL_POOLED', passed)
    print(f'STALL POOLED reference={pooled_r}/{2000 * len(references)} candidate={pooled_c}/2000 p={p:.12g} p_value={tail:.12g} result={status}')
    for key in ('SIX_THOUSAND_TOGGLE_MS', 'POPULATED_TOGGLE_MS'):
        maximum = max(candidate['PF'][key])
        status = verdict(f'CEILING_{key}', maximum <= 120)
        print(f'CEILING {key} maximum={maximum:.9f} limit=120 result={status}')
    return results


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True)
    parser.add_argument('--candidate', required=True)
    parser.add_argument('--base-after')
    parser.add_argument('--prior-run', action='append', default=[], type=Path,
                        help='Earlier same-candidate run directory containing pf-base.log, '
                             'pf-candidate.log and pf-base-after.log (at most two, oldest first)')
    try:
        args = parser.parse_args(argv)
    except SystemExit as error:
        return 0 if error.code == 0 else 3
    try:
        if len(args.prior_run) > 2 or (args.prior_run and not args.base_after):
            raise ValueError('carry-forward requires paired runs within the three-run budget')
        paths = [(root / 'pf-base.log', root / 'pf-candidate.log', root / 'pf-base-after.log')
                 for root in args.prior_run]
        paths.append((args.base, args.candidate, args.base_after))
        for b, c, a in paths:
            logs = [Path(path).read_text() for path in [b, c] + ([a] if a else [])]
            fresh = ['PF_FRESH_OPEN_SAMPLE_JSON=' in log for log in logs]
            if any(fresh) and not all(fresh):
                raise ValueError('fresh open growth must use matched base/candidate/base-after samples')
        attempts = [(parse_log(b), parse_log(c), parse_log(a) if a else None)
                    for b, c, a in paths]
        base = attempts[0][0]
        for b, c, a in attempts:
            if any(run[group].keys() != base[group].keys()
                   for run in [b, c] + ([a] if a else []) for group in base):
                raise ValueError('runs have different metric sets')
            if a and not COLD_KEYS <= b['PF'].keys():
                raise ValueError('three-run gate requires cold metrics')
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'INPUT ERROR: {error}', file=sys.stderr)
        return 3
    passed_rows, failed_rows = set(), set()
    for number, (base, candidate, after) in enumerate(attempts, 1):
        print(f'\nRUN {number}')
        if after:
            forward = evaluate(after, [base], 'A/A B′ against B')
            reverse = evaluate(base, [after], 'A/A B against B′')
            eligible = {row for row in forward if forward[row] and reverse[row]}
            print(f'A/A VERDICT: {"VALID" if len(eligible) == len(forward) else "PARTIALLY UNMEASURABLE" if eligible else "UNMEASURABLE"}')
            # OD-12: a candidate ceiling pass is independent of base validity.
            # A breach stays unmeasurable unless both bases meet the ceiling.
            for key in ('SIX_THOUSAND_TOGGLE_MS', 'POPULATED_TOGGLE_MS'):
                for role, run in (('B', base), ('B′', after)):
                    maximum = max(run['PF'][key])
                    print(f'BASE CEILING {key} role={role} maximum={maximum:.9f} limit=120 result={"PASS" if maximum <= 120 else "FAIL"} (diagnostic)')
                if max(candidate['PF'][key]) <= 120:
                    eligible.add(f'CEILING_{key}')
        else:
            eligible = None
            print('A/A VERDICT: SKIPPED (single reference retro-check)')
        results = evaluate(candidate, [base] + ([after] if after else []),
                           'Candidate against pooled reference (diagnostic until row validity is applied)', eligible)
        if eligible is None:
            eligible = set(results)
        passed_rows.update(row for row in eligible if results[row])
        failed_rows.update(row for row in eligible if not results[row])
        carried = set(results) - passed_rows - failed_rows
        print(f'\nPER-ROW RUN {number}')
        print('| Row | Judged | Unmeasurable | Pass | Fail |')
        print('| --- | --- | --- | --- | --- |')
        for row in sorted(results):
            judged = row in eligible
            print(f'| {row} | {"yes" if judged else "no"} | {"no" if judged else "yes"} | '
                  f'{"yes" if judged and results[row] else "—"} | {"yes" if judged and not results[row] else "—"} |')
        print(f'ROW SUMMARY RUN {number}: judged={len(eligible)} unmeasurable={len(results) - len(eligible)} '
              f'pass={sum(results[row] for row in eligible)} fail={sum(not results[row] for row in eligible)}')
        print('CARRIED ROWS: ' + (', '.join(sorted(carried)) or 'none'))
        print('FAILED ROWS: ' + (', '.join(sorted(failed_rows)) or 'none'))
    code = 1 if failed_rows else (2 if carried else 0)
    print(f'GATE: {("PASS", "CANDIDATE FAILURE", "UNMEASURABLE")[code]} exit={code}')
    return code


if __name__ == '__main__':
    sys.exit(main())
