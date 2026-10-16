#!/usr/bin/env python3
"""Retain raw dropdown cost attempts and pooled decisions in the job summary."""
import json
from pathlib import Path
import sys


def evidence_lines(value):
    if isinstance(value, str):
        yield from (line for line in value.splitlines() if line.startswith('DROPDOWN_COST_EVIDENCE'))
    elif isinstance(value, dict):
        for child in value.values():
            yield from evidence_lines(child)
    elif isinstance(value, list):
        for child in value:
            yield from evidence_lines(child)


def main(path):
    lines = list(dict.fromkeys(evidence_lines(json.loads(path.read_text()))))
    if not lines:
        raise ValueError('missing dropdown cost evidence')
    print('## Dropdown cost attempts (OD-15 amended)\n\n```text')
    print('\n'.join(lines))
    print('```')


if __name__ == '__main__':
    main(Path(sys.argv[1]))
