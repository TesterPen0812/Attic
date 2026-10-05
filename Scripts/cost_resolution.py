"""OD-9 timing bounds shared by the same-job cost comparators.

Infer the smallest nonzero step within the reference's raw sample series.
A between-build shift is not resolution: [40]*3 -> [42]*3 must not grant
the candidate a 2 ms quantum. Nor can candidate outliers widen it. Fixtures
may report their documented timer quantum, including when samples are flat.
Without distinct samples or a reported quantum, grant no invented slack.
"""
import math
import ast
import re
import statistics


def fixture_quantum(texts, metric):
    """Optional fixture metadata, in milliseconds; conflicting reports fail."""
    pattern = r"ATTIC_COST_QUANTUM metric=(\S+) quantum_ms=([\d.eE+-]+)"
    values = {float(value) for text in texts for name, value in re.findall(pattern, text)
              if name == metric}
    if len(values) > 1:
        raise ValueError(f"{metric}: inconsistent fixture timer quanta")
    return next(iter(values), None)


def raw_samples(texts, metric):
    pattern = r"ATTIC_COST_SAMPLES metric=(\S+) raw_ms=(\[[^\n]+?\])"
    return [float(value) for text in texts for name, raw in re.findall(pattern, text)
            if name == metric for value in ast.literal_eval(raw)]


def compare(before, after, quantum_ms=None, reference_samples=None):
    if not before or not after or not all(map(math.isfinite, before + after)):
        raise ValueError("missing or nonfinite cost samples")
    if quantum_ms is not None:
        if not math.isfinite(quantum_ms) or quantum_ms <= 0:
            raise ValueError("timer quantum must be finite and positive")
        resolution = quantum_ms
        source = "fixture quantum"
    else:
        calibration = before if reference_samples is None else reference_samples
        if not calibration or not all(map(math.isfinite, calibration)):
            raise ValueError("missing or nonfinite resolution samples")
        distinct = sorted(set(calibration))
        steps = [right - left for left, right in zip(distinct, distinct[1:])]
        resolution = min(steps, default=0.0)
        source = "reference samples" if steps else "flat samples; no reported quantum"
    reference_range = max(before) - min(before)
    tolerance = max(reference_range, resolution) + 0.2
    bound = statistics.median(before) + tolerance
    return dict(before_ms=before, after_ms=after, reference_range_ms=reference_range,
                resolution_ms=resolution, resolution_source=source, noise_ms=tolerance,
                bound_ms=bound, passed=statistics.median(after) <= bound)
