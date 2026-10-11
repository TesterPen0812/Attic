#!/usr/bin/env python3
"""Compare adjacent AB/BA reveal pairs; no fixed millisecond allowance.

Use fresh owned stores, the same configuration and display, and reverse the
launch order in alternate pairs. The median paired difference must not exceed
zero: the candidate must be no slower than the measured reference.
"""
import argparse
import json
import math
import statistics
from pathlib import Path


def reveal(document):
    if document.get('bundle') != 'com.taha.Attic.preview.phasex':
        raise ValueError('Expected the isolated phasex preview')
    values = [r['milliseconds'] for r in document['timings']
              if r['name'] == 'PanelRevealToOrderedFront']
    if len(values) != 1 or not math.isfinite(values[0]) or values[0] <= 0:
        raise ValueError('Expected exactly one finite cold reveal')
    return values[0]


def compare(pairs):
    if len(pairs) < 2:
        raise ValueError('At least two interleaved AB/BA pairs are required')
    before = [reveal(a) for a, _ in pairs]
    after = [reveal(b) for _, b in pairs]
    deltas = [b - a for a, b in zip(before, after)]
    return dict(reference_ms=before, candidate_ms=after, paired_deltas_ms=deltas,
                reference_spread_ms=max(before) - min(before),
                candidate_spread_ms=max(after) - min(after),
                median_paired_delta_ms=statistics.median(deltas),
                passed=statistics.median(deltas) <= 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pair', nargs=2, action='append', required=True,
                        metavar=('REFERENCE_JSON', 'CANDIDATE_JSON'))
    args = parser.parse_args()
    result = compare([(json.loads(Path(a).read_text()), json.loads(Path(b).read_text()))
                      for a, b in args.pair])
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)


if __name__ == '__main__':
    main()
