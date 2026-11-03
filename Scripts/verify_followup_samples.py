#!/usr/bin/env python3
"""Check the paired, uniform-backdrop SCK samples; legacy replays the reported capture."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('path', type=Path)
parser.add_argument('--legacy', action='store_true')
args = parser.parse_args()
if args.legacy:
    from PIL import Image
    image = Image.open(args.path).convert('RGB')
    def sample(x, y):
        return [sum(image.getpixel((x + dx, y + dy))[c] for dx in range(-1, 2) for dy in range(-1, 2)) / 9 for c in range(3)]
    panel, island = sample(300, 104), sample(379, 104)
    cases = [(args.path.name, {'panelRGB': panel, 'islandRGB': island,
        'absoluteDifference': [abs(a - b) for a, b in zip(panel, island)]})]
else:
    cases = [(p.stem, json.loads(p.read_text())) for p in sorted(args.path.glob('*.png.json'))]
    if len(cases) != 12:
        raise SystemExit(f'Expected all 12 combinations, found {len(cases)}')
failed = []
for name, result in cases:
    difference = max(result['absoluteDifference'])
    print(f"{name}: panel={result['panelRGB']} island={result['islandRGB']} max-channel-difference={difference:.2f}/255")
    if difference > 12:
        failed.append(name)
print(f'{len(cases)} cases, {len(failed)} failures (maximum channel difference 12/255)')
raise SystemExit(bool(failed))
