#!/usr/bin/env python3
"""Find bright clusters (text/handles) in a captured BMP.
Usage: measure_bright.py FILE.bmp X0 Y0 X1 Y1 THRESH MIN_SIZE
Coords are in 2x pixels; prints clusters: center_pt(x,y) count bbox_pt
"""
import struct, collections, sys

path, x0, y0, x1, y1, thr, minsz = sys.argv[1], *map(int, sys.argv[2:8])
f = open(path, "rb").read()
off = struct.unpack_from("<I", f, 10)[0]
w = struct.unpack_from("<i", f, 18)[0]
h = abs(struct.unpack_from("<i", f, 22)[0])
bpp = struct.unpack_from("<H", f, 28)[0]
row = (w * (bpp // 8) + 3) // 4 * 4

def get(x, y):
    y2 = h - 1 - y
    p = off + y2 * row + x * (bpp // 8)
    return f[p + 2], f[p + 1], f[p]

seen = [[False] * w for _ in range(h)]
res = []
for y in range(y0, min(y1, h)):
    for x in range(x0, min(x1, w)):
        if seen[y][x]:
            continue
        r0, g0, b0 = get(x, y)
        if r0 >= thr and g0 >= thr and b0 >= thr:
            q = collections.deque([(x, y)]); seen[y][x] = True
            cells = []
            while q:
                cx, cy = q.popleft(); cells.append((cx, cy))
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = cx + dx, cy + dy
                    if x0 <= nx < x1 and y0 <= ny < y1 and not seen[ny][nx]:
                        rr, gg, bb = get(nx, ny)
                        if rr >= thr and gg >= thr and bb >= thr:
                            seen[ny][nx] = True; q.append((nx, ny))
            if len(cells) >= minsz:
                xs = [c[0] for c in cells]; ys = [c[1] for c in cells]
                res.append((round(sum(xs)/len(cells)/2, 1), round(sum(ys)/len(cells)/2, 1),
                            len(cells), (round(min(xs)/2, 1), round(min(ys)/2, 1),
                                         round(max(xs)/2, 1), round(max(ys)/2, 1))))
res.sort(key=lambda c: (c[1], c[0]))
print("clusters (pt): center | count | bbox(pt, 2x-normalized)")
for cx, cy, n, bb in res:
    print(f"  ({cx},{cy}) n={n} bbox={bb}")
