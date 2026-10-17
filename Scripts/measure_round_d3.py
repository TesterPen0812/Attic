#!/usr/bin/env python3
"""Package exported D3 XCTest attachments; no screen or application access.

Usage: python3 Scripts/measure_round_d3.py ATTACHMENTS phaseX/round-d3
Requires Pillow only for the derived contact sheets and pixel measurements.
"""
import csv
import json
from pathlib import Path
import re
import shutil
import sys

from PIL import Image, ImageChops, ImageDraw

source, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
renders = output / "renders"
renders.mkdir(exist_ok=True)
manifest = json.loads((source / "manifest.json").read_text())
rows, images = [], {}
for test in manifest:
    for attachment in test["attachments"]:
        name = attachment["suggestedHumanReadableName"]
        file = source / attachment["exportedFileName"]
        if name.startswith("d3-measurements_"):
            rows.extend(json.loads(file.read_text()))
        if name.startswith("d3-") and file.suffix == ".png":
            name = re.split(r"_\d+_", name)[0] + ".png"
            shutil.copyfile(file, renders / name)
            images[name] = {"exportedFile": file.name, "test": test.get("testIdentifier", ""),
                            "timestamp": attachment["timestamp"]}

assert rows, "No D3 measurement attachments"
baseline = {(r["role"], r["fixture"]): r for r in rows if r["variant"] == "A-fixed"}
flat = []
for row in rows:
    original = baseline[row["role"], row["fixture"]]
    row["visualBaselineDeltaFromA"] = row["inkBaseline"] - original["inkBaseline"]
    row["caretTopDeltaFromA"] = row["caret"]["y"] - original["caret"]["y"]
    record = {k: v for k, v in row.items() if isinstance(v, (str, int, float))}
    for field in ["caret", "line", "selection", "standardPoint", "capDescenderBand", "xHeightBand"]:
        if isinstance(row[field], dict):
            record.update({field + "." + key: value for key, value in row[field].items()})
    record["hasStandardSegment"] = row["standardPoint"] is not None
    record["hasSelectionSegment"] = row["selection"] is not None
    flat.append(record)
(output / "measurements.json").write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n")
(output / "render-manifest.json").write_text(json.dumps(images, indent=2, sort_keys=True) + "\n")
with (output / "geometry.csv").open("w") as file:
    fields = list(dict.fromkeys(key for row in flat for key in row))
    writer = csv.DictWriter(file, fields, lineterminator="\n"); writer.writeheader(); writer.writerows(flat)

pixels = {}
for name in images:
    if "selection" in name:
        continue
    im = Image.open(renders / name).convert("RGB")
    red, green, blue = im.split()
    mask = ImageChops.multiply(red.point(lambda v: 255 if v < 90 else 0),
                              blue.point(lambda v: 255 if v > 160 else 0))
    mask = ImageChops.multiply(mask, green.point(lambda v: 255 if 60 < v < 200 else 0))
    box = mask.getbbox()
    if box:
        pixels[name] = {"left": box[0], "top": box[1], "width": box[2] - box[0],
                        "height": box[3] - box[1], "scale": 2}
    else:
        pixels[name] = None
(output / "caret-pixels.json").write_text(json.dumps(pixels, indent=2, sort_keys=True) + "\n")

for fixture in ["typed", "empty", "wrapped-middle", "selection"]:
    variants = ["A-fixed", "B-calibrated", "E-shell", "F-default"]
    sheet = Image.new("RGB", (4 * 300, 4 * 176), "#eeeeee")
    draw = ImageDraw.Draw(sheet)
    for iy, role in enumerate(["body", "h1", "h2", "h3"]):
        for ix, variant in enumerate(variants):
            name = f"d3-{role}-{variant}-{fixture}.png"
            im = Image.open(renders / name).convert("RGB")
            # Native 2x pixels; crops retain identical document coordinates.
            crop = im.crop((34, 18 if fixture != "wrapped-middle" else 90,
                            334, 158 if fixture != "wrapped-middle" else 230))
            x, y = ix * 300, iy * 176
            draw.text((x + 5, y + 4), f"{role} / {variant} / {fixture}", fill="#111111")
            sheet.paste(crop, (x, y + 24))
    sheet.save(output / f"comparison-{fixture}.png")

checks = []
for role in ["body", "h1", "h2", "h3"]:
    for fixture in ["typed", "wrapped-first", "wrapped-middle"]:
        a = Image.open(renders / f"d3-{role}-A-fixed-{fixture}.png").convert("RGB")
        b = Image.open(renders / f"d3-{role}-E-shell-{fixture}.png").convert("RGB")
        box = (0, 0, min(a.width, b.width), min(a.height, b.height))
        def ink(im):
            red, green, blue = im.crop(box).split()
            return ImageChops.multiply(ImageChops.multiply(
                red.point(lambda v: 255 if v > 180 else 0),
                green.point(lambda v: 255 if v > 180 else 0)),
                blue.point(lambda v: 255 if v > 180 else 0))
        diff = ImageChops.difference(ink(a), ink(b))
        record = next(r for r in rows if r["role"] == role and r["variant"] == "A-fixed" and r["fixture"] == fixture)
        anchor = int(record["caret"]["x"] * 2)
        # Different-height native strokes can occlude nearby text differently.
        ImageDraw.Draw(diff).rectangle((anchor - 4, 0, anchor + 4, diff.height), fill=0)
        changed = sum(value > 0 for value in diff.getdata())
        checks.append({"role": role, "fixture": fixture, "changedInkPixelsOutsideCaretStrip": changed,
                       "comparedPixelRect": box, "excludedX": [anchor - 4, anchor + 4]})
(output / "glyph-position-check.json").write_text(json.dumps(checks, indent=2) + "\n")

print(f"Packaged {len(rows)} rows, {len(images)} native renders, four contact sheets")
