#!/usr/bin/env python3
"""Overlay current measurement fixtures on the pinned integration reference.

Only selected cost tests and their supporting helpers belong in this overlay.
Unselected functional tests can depend on later app APIs. Candidate functional
coverage stays in the full hosted suite; reference app/project sources stay put.
The fixtures use four-space method indentation; reject ambiguous boundaries.
"""
from pathlib import Path
import re
import sys

from recheck_cost_gates import INTEGRATION_TESTS, QUERIES, RENDERED, ROOT

SELECTED = INTEGRATION_TESTS + QUERIES + [RENDERED]
METHOD = re.compile(r'^    (?:private )?func (\w+)\(', re.MULTILINE)


def measurement_fixture(source, selected):
    methods = list(METHOD.finditer(source))
    found = set()
    removals = []
    for method in methods:
        name = method.group(1)
        if name in selected:
            if name in found:
                raise ValueError(f'duplicate measurement method: {name}')
            found.add(name)
            continue
        if not name.startswith('test') and name != 'pendingCheckpointQuit':
            continue
        line_end = source.index('\n', method.start())
        if source[method.start():line_end].rstrip().endswith('}'):
            end = line_end + 1
        else:
            closing = re.search(r'^    }\s*$', source[line_end:], re.MULTILINE)
            if not closing:
                raise ValueError(f'missing method boundary: {name}')
            end = line_end + closing.end()
            if any(method.start() < other.start() < end for other in methods):
                raise ValueError(f'ambiguous method boundary: {name}')
        removals.append((method.start(), end))
    if found != set(selected):
        raise ValueError(f'missing measurements: {set(selected) - found}')
    for start, end in reversed(removals):
        source = source[:start] + source[end:]
    return source


def prepare(directory):
    by_fixture = {}
    for selection in SELECTED:
        fixture, method = selection.split('/')
        by_fixture.setdefault(fixture, set()).add(method)
    # Prepare everything before changing the archived fixtures.
    updates = {}
    for fixture, selected in by_fixture.items():
        path = directory / 'AtticTests' / f'{fixture}.swift'
        if not path.is_file():
            raise ValueError(f'missing pinned fixture: {path}')
        source = (ROOT / 'AtticTests' / path.name).read_text()
        updates[path] = measurement_fixture(source, selected)
    for path, source in updates.items():
        path.write_text(source)
        print(f'Measurement-only integration reference overlay: {path}')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]))
