#!/bin/zsh
# Usage: Scripts/symbolicate_idle_samples.zsh idle.log /path/to/Attic.app
# The log must be from: /usr/bin/log show --style compact ...
emulate -L zsh
set -euo pipefail
if (( $# != 2 )); then
  print -u2 'usage: symbolicate_idle_samples.zsh <log-file> <Attic.app|executable>'
  exit 2
fi
python3 - "$1" "$2" <<'PY'
import collections
import pathlib
import plistlib
import re
import subprocess
import sys

source, app = sys.argv[1:]
if app.endswith('.app'):
    bundle = pathlib.Path(app)
    with (bundle / 'Contents/Info.plist').open('rb') as f:
        exe = bundle / 'Contents/MacOS' / plistlib.load(f)['CFBundleExecutable']
else:
    exe = pathlib.Path(app)
if not exe.is_file():
    sys.exit(f'Executable not found: {exe}')

lines = open(source, encoding='utf-8', errors='replace')
images, raw_samples = {}, []
for line in lines:
    match = re.search(r'\bsample_image id=(\d+) image=(\d+) name=(\S+) uuid=([\w-]*)', line)
    if match:
        action, image_id, name, uuid = match.groups()
        images[(action, image_id)] = (name, uuid)
    match = re.search(r'\bsample id=(\d+) n=\d+ .*?stack=([^\s]+)', line)
    if match:
        action, stack = match.groups()
        if stack != '':
            raw_samples.append((action, stack))

samples = collections.Counter()
for action, stack in raw_samples:
    canonical = []
    for item in stack.split(','):
        match = re.fullmatch(r'(\d+)\+(0x[\da-fA-F]+)', item)
        if match:
            binary, uuid = images.get((action, match.group(1)), ('unknown', ''))
            canonical.append(f'{binary}[{uuid}]+{match.group(2)}')
        else:
            canonical.append(item)
    samples[tuple(canonical)] += 1

if not samples:
    sys.exit('No completed IdleLatency sample stacks found in the log.')

cache = {}
binary_info = {}

def matching_binary(name):
    # Local builds may put all app code in Attic.debug.dylib, with a tiny
    # executable stub. The image table tells us which binary held each PC.
    candidate = exe if name == exe.name else exe.parent / name
    return candidate if candidate.is_file() else None

def info_for(binary):
    if binary not in binary_info:
        uuids = {item.lower() for item in re.findall(r'UUID: ([\w-]+)', subprocess.run(
            ['/usr/bin/dwarfdump', '--uuid', str(binary)], capture_output=True,
            text=True, check=False).stdout, re.I)}
        segments = subprocess.run(['/usr/bin/otool', '-l', '-arch', 'arm64', str(binary)],
                                  capture_output=True, text=True, check=False).stdout
        match = re.search(r'\bsegname __TEXT\s+vmaddr (0x[\da-fA-F]+)', segments)
        binary_info[binary] = (uuids, int(match.group(1), 16) if match else None)
    return binary_info[binary]

def frame_label(item):
    match = re.fullmatch(r'(.+)\[([^]]*)\]\+(0x[\da-fA-F]+)', item)
    if not match:
        return item
    name, uuid, offset = match.groups()
    raw = item
    binary = matching_binary(name)
    if binary is None:
        return raw
    uuids, base = info_for(binary)
    if uuid and uuid.lower() not in uuids:
        return raw + ' (UUID mismatch)'
    if base is None:
        return raw + ' (unknown __TEXT address)'
    if item not in cache:
        # Logged offsets are relative to the loaded Mach-O header. Use this
        # image's linked __TEXT vmaddr (0 for dylibs, 0x100000000 for apps).
        address = hex(base + int(offset, 16))
        result = subprocess.run(['/usr/bin/atos', '-arch', 'arm64', '-o', str(binary),
                                 '-l', hex(base), address],
                                capture_output=True, text=True, check=False)
        cache[item] = result.stdout.strip() or raw
    return f'{cache[item]} ({raw})'

print(f'{sum(samples.values())} samples; top stacks (image UUIDs and relative offsets):')
for stack, count in samples.most_common(10):
    print(f'\n{count}x')
    for entry in stack[:16]:
        print('  ' + frame_label(entry))
PY
