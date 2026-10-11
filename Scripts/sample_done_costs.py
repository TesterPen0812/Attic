#!/usr/bin/env python3
"""Eight AB/BA invocations, three fresh sessions each, with unchanged gates.

Pair/session identity is retained for drift diagnostics. The comparator still
uses the same median + max(reference range, resolution) + 0.2 ms formula on
all 24 raw readings; paired deltas do not replace the acceptance oracle.
"""
import json
from pathlib import Path
import statistics
import sys

PAIRS = 8
RENDERED = 'DoneSearchCostTests/testRenderedFindKeystrokeMediansFitTheInputBudget'


def order(pair):
    return ['baseline', 'candidate'] if pair % 2 else ['candidate', 'baseline']


def collect(directory, run):
    directory.mkdir(parents=True, exist_ok=True)
    manifest = dict(version=1, pairs=[])
    # Write before sampling, so interruption can never fall back to old logs.
    path = directory / 'done-rendered-pairs.json'
    path.write_text(json.dumps(manifest, indent=2) + '\n')
    for pair in range(1, PAIRS + 1):
        for side in order(pair):
            build = 'integrationbase' if side == 'baseline' else 'candidate'
            run(directory, side, build, [RENDERED], f'rendered-{side}-{pair}.log')
        manifest['pairs'].append(dict(pair=pair, order=order(pair)))
        path.write_text(json.dumps(manifest, indent=2) + '\n')
    # Validate complete logs and retain pair/session phase deltas as evidence.
    from check_integration_costs import rendered
    before, after, texts = readings(directory, rendered)
    deltas = {name: [b - a for a, b in zip(before[name], after[name])] for name in before}
    phases = []
    import ast
    import re
    pattern = r'ATTIC_DONE_KEY_PHASE run=(\d+) key=(\d+) change/runloop/layout/display/commit_ms=(\[[^\n]+?\])'
    for pair in range(1, PAIRS + 1):
        sides = [{(int(run), int(key)): ast.literal_eval(raw) for run, key, raw in re.findall(pattern, text)}
                 for text in texts[(pair - 1) * 2:pair * 2]]
        if set(sides[0]) != set(sides[1]):
            raise ValueError('incomplete paired Done phases')
        for (session, key), reference in sorted(sides[0].items()):
            candidate = sides[1][session, key]
            if len(reference) != 5 or len(candidate) != 5:
                raise ValueError('expected five Done phases')
            phases.append(dict(pair=pair, session=session, key=key,
                               delta_ms=[b - a for a, b in zip(reference, candidate)]))
    diagnostics = dict(samples_per_side=PAIRS * 3, phase_deltas=phases,
                       rows={name: dict(paired_delta_ms=values,
                                        paired_delta_variance_ms2=statistics.variance(values))
                             for name, values in deltas.items()})
    (directory / 'done-paired-diagnostics.json').write_text(json.dumps(diagnostics, indent=2) + '\n')


def readings(directory, parse):
    manifest = json.loads((directory / 'done-rendered-pairs.json').read_text())
    expected = [dict(pair=pair, order=order(pair)) for pair in range(1, PAIRS + 1)]
    if manifest != dict(version=1, pairs=expected):
        raise ValueError('expected eight complete alternating AB/BA Done pairs')
    samples = {'baseline': {}, 'candidate': {}}
    texts = []
    for pair in range(1, PAIRS + 1):
        # Fixed diagnostic order independent of execution order.
        for side in ('baseline', 'candidate'):
            text = (directory / f'rendered-{side}-{pair}.log').read_text()
            texts.append(text)
            rows = parse(text, reference_only=side == 'baseline')
            for name, values in rows.items():
                samples[side].setdefault(name, []).extend(values)
    return samples['baseline'], samples['candidate'], texts


if __name__ == '__main__':
    from recheck_cost_gates import Sampler
    collect(Path(sys.argv[1]), Sampler().run)
