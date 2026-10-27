#!/usr/bin/env python3
"""WindowServer-frame observations, never photons. No capture-delay subtraction.

Ports analyze-video.py / audit-witnesses.py, with explicit geometry, clock and
paths. Retained evidence has no movies/luma: validate its extracted joins instead.
"""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
from statistics import median

LIMIT = ('ScreenCaptureKit complete WindowServer frames; exposed witnesses only; '
         'capture overhead and scanout uncalibrated; gaps are not physical hitches; '
         'no assumed delay subtraction.')
QUANTILES = (50, 95, 99, 100)


def rows(path):
    with Path(path).open(newline='') as f:
        return list(csv.DictReader(f))


def percentile(values, q):
    ordered = sorted(values)
    if not ordered:
        raise ValueError('empty distribution')
    if not all(math.isfinite(x) for x in ordered):
        raise ValueError('nonfinite observations')
    at = (len(ordered)-1)*q/100
    a, b = math.floor(at), math.ceil(at)
    return ordered[a] + (ordered[b]-ordered[a])*(at-a)


def dist(values):
    return {str(q): percentile(values, q) for q in QUANTILES}


def dump(path, value, *, exclusive=False):
    with Path(path).open('x' if exclusive else 'w') as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write('\n')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def exposed(x, y, width, height, excluded=()):
    return (6 < x < width-6 and 6 < y < height-6
            and not any(a <= x <= a+w and b <= y <= b+h for a, b, w, h in excluded))


def pixel_witnesses(directory):
    # Only the pixel extraction requires numpy/Pillow (the retained helpers used
    # them too); all gates and retained validation use the standard library.
    import numpy as np
    from PIL import Image, ImageDraw
    p = Path(directory)
    frames, events, driver = rows(p/'screen-frames.csv'), rows(p/'events.csv'), rows(p/'driver.csv')
    settings = json.loads((p/'capture-settings.json').read_text())
    app = json.loads((p/'settings.json').read_text())
    if not frames or not events:
        raise ValueError('no frames/events')
    width, height, stride = (int(frames[0][k]) for k in ('width','height','stride'))
    expected = len(frames)*height*stride
    if (p/'gray.bin').stat().st_size != expected:
        raise ValueError('luma/frame sidecar length mismatch')
    pixels = np.memmap(p/'gray.bin', dtype=np.uint8, mode='r', shape=(len(frames),height,stride))[:,:,:width]
    times = np.array([float(r['display_monotonic_s']) for r in frames])
    start = float(events[0]['event_monotonic_s'])
    baseline = np.where(times < start)[0]
    if not len(baseline):
        raise ValueError('missing pre-input baseline')
    base = pixels[baseline[-1]]
    ox, oy, ww, wh = settings['window_frame_cg_pt']
    sx, sy = width/ww, height/wh
    # Coordinates in the capture are top-left; controls are specified in points.
    exclusions = [[75*sx,8*sy,170*sx,40*sy]] if app['glass'] != 'off' else []
    posted = {r['sequence']: r for r in driver}
    mask = Image.new('1',(width,height)); draw = ImageDraw.Draw(mask)
    previous = None; witnesses = []; eligible = 0; missing = 0
    for event in events:
        if event['type'] == '2':
            previous = None
            continue
        d = posted[event['driver_sequence']]
        x = round((float(d['x'])-ox)*sx); y = round((float(d['y'])-oy)*sy)
        visible = exposed(x,y,width,height,exclusions)
        if previous is not None and visible and np.min(base[y-1:y+2,x-1:x+2]) > 200 and not mask.getpixel((x,y)):
            eligible += 1
            patch = pixels[:,y-1:y+2,x-1:x+2]
            dark = (pixels[:,y,x] < 90) & (np.count_nonzero(patch < 90,axis=(1,2)) >= 3)
            # Search ALL frames, not only after event time: early/preexisting
            # darkness is an invalid witness, never silently clipped to zero.
            hits = np.where(dark)[0]
            if len(hits):
                index = int(hits[0]); event_s = float(event['event_monotonic_s'])
                submit = float(event['ca_commit_submit_s'])
                witnesses.append(dict(sequence=event['sequence'],driver_sequence=event['driver_sequence'],
                    event_s=event_s,ca_submit_s=submit,frame=index,presented_s=float(times[index]),
                    event_to_present_ms=(times[index]-event_s)*1000,
                    submit_to_present_ms=(times[index]-submit)*1000,x_px=x,y_px=y))
            else:
                missing += 1
        radius = math.ceil(sx) + 1 # 2pt ink radius + 1px witness-patch radius
        if previous is not None:
            draw.line([previous,(x,y)],fill=1,width=radius*2)
        draw.ellipse((x-radius,y-radius,x+radius,y+radius),fill=1)
        previous = (x,y)
    if not witnesses:
        raise ValueError('zero exposed witnesses')
    with (p/'ink-presentations.csv').open('w',newline='') as f:
        writer = csv.DictWriter(f,fieldnames=list(witnesses[0]));writer.writeheader();writer.writerows(witnesses)
    dump(p/'witness-coverage.json',dict(eligible=eligible,missing=missing,observed=len(witnesses)))
    return summarize(p)


def summarize(directory, *, handler_only=False):
    p = Path(directory)
    events, driver, frames = (rows(p/name) for name in ('events.csv','driver.csv','screen-frames.csv'))
    witness_path = p/'ink-presentations.csv'
    witnesses = [] if handler_only else rows(witness_path)
    # Scroll events are deliberately not accepted ink samples.
    posted = {r['sequence']:r for r in driver if r['type'] in ('1','2','6')}
    accepted = [r['driver_sequence'] for r in events]
    mode=json.loads((p/'settings.json').read_text())['mode']
    problems = []
    if len(set(accepted)) != len(accepted): problems.append('duplicate accepted sample')
    if set(accepted) != set(posted): problems.append('posted/delivered sample loss or unmatched sample')
    if not events or not frames or (not witnesses and not handler_only): raise ValueError('missing evidence')
    if any(int(r['index']) != i for i,r in enumerate(frames)): problems.append('dropped frame-sidecar sample')
    if any(r['video_appended'] != 'true' for r in frames): problems.append('encoder drops')
    ts = [float(r['display_monotonic_s']) for r in frames]
    if any(b <= a for a,b in zip(ts,ts[1:])): problems.append('nonmonotonic capture')
    by_event = {r['sequence']:r for r in events}
    metrics = {name:[] for name in ('post_handler','event_handler','handler_overlay','handler_submit','event_submit','event_pixels','submit_pixels')}
    for e in events:
        event, handler, overlay, submit = (float(e[k]) for k in ('event_monotonic_s','handler_s','overlay_s','ca_commit_submit_s'))
        if not event <= handler <= overlay <= submit: problems.append('noncausal event pipeline')
        d = posted.get(e['driver_sequence'])
        if d: metrics['post_handler'].append((handler-float(d.get('post_s',d['event_monotonic_s'])))*1000)
        for name,value in [('event_handler',handler-event),('handler_overlay',overlay-handler),('handler_submit',submit-handler),('event_submit',submit-event)]:
            metrics[name].append(value*1000)
    seen = set()
    for r in witnesses:
        if r['sequence'] in seen: problems.append('duplicate witness')
        seen.add(r['sequence'])
        e = by_event.get(r['sequence']); index = int(r['frame'])
        if e is None or index < 0 or index >= len(ts): raise ValueError('unjoined witness')
        presented = float(r['presented_s'])
        if abs(presented-ts[index]) > 1e-6: raise ValueError('witness/frame timestamp mismatch')
        latency = (presented-float(e['event_monotonic_s']))*1000
        submit_latency = (presented-float(e['ca_commit_submit_s']))*1000
        if mode != 'c3' and (latency < 0 or submit_latency < -0.25): problems.append('negative witness latency')
        metrics['event_pixels'].append(latency);metrics['submit_pixels'].append(submit_latency)
    intervals = [(b-a)*1000 for a,b in zip(ts,ts[1:])]
    metrics['capture_interval'] = intervals
    observed_grid = median(intervals)
    # Verify a 120-Hz timestamp grid; do NOT claim 120 distinct frames/sec.
    if abs(observed_grid-1000/120) > 1: problems.append('120 Hz capture grid unverified')
    summary = dict(valid=not problems,problems=sorted(set(problems)),limits=LIMIT,
        metrics={k:dist(v) for k,v in metrics.items() if v},posted=len(posted),delivered=len(events),accepted=len(events),
        witnesses=len(witnesses),witness_coverage=len(witnesses)/len(events),complete_frames=len(frames),
        distinct_complete_fps=(len(ts)-1)/(ts[-1]-ts[0]),
        mode=mode,handler_only=handler_only)
    if (p/'witness-coverage.json').exists():
        summary['exposure'] = json.loads((p/'witness-coverage.json').read_text())
        if summary['exposure']['missing']:
            summary['valid'] = False; summary['problems'].append('eligible exposed samples never visible')
    dump(p/'summary.json',summary)
    return summary


def freeze(reference_paths, output):
    if len(reference_paths) < 3: raise ValueError('need >=3 fresh reference runs')
    refs = [json.loads(Path(p).read_text()) for p in reference_paths]
    if any(not r['valid'] or r['mode'] != 'reference' for r in refs): raise ValueError('invalid/nonreference calibration')
    ceilings = {}; centers = {}; spreads = {}; unstable = []
    for metric in refs[0]['metrics']:
        ceilings[metric] = {}; centers[metric] = {}; spreads[metric] = {}
        for q in map(str,QUANTILES):
            values = [r['metrics'][metric][q] for r in refs]
            spread = max(values)-min(values); center = median(values)
            ceilings[metric][q] = max(values)+spread
            centers[metric][q] = center; spreads[metric][q] = spread
            # Predeclared stability bound, never derived from candidates.
            if metric in ('event_pixels','event_handler','event_submit') and q in ('50','95') and spread > max(1,center*0.20):
                unstable.append(f'{metric}:{q}')
    result = dict(ceilings=ceilings,centers=centers,spreads=spreads,stable=not unstable,unstable=unstable,
        reference_sha256=[digest(p) for p in reference_paths],limits=LIMIT,
        rule='ceiling=max(reference repeats)+(max-min); stability spread<=max(1ms,20% median) for primary median/p95')
    dump(output,result,exclusive=True) # freeze cannot be overwritten
    return result


def compare(floor, candidate):
    if not floor['stable']: return dict(status='inconclusive',reason='unstable frozen references')
    failures = list(candidate['problems'])
    for metric, quantiles in floor['ceilings'].items():
        for q, ceiling in quantiles.items():
            if candidate['metrics'][metric][q] > ceiling:
                failures.append(f'{metric}:{q} exceeds frozen ceiling')
    if not candidate['valid']: failures.append('invalid evidence')
    prediction = candidate['mode'] == 'c3'
    goal = (not failures and not prediction and all(candidate['metrics']['event_pixels'][q] <= 0.8*floor['centers']['event_pixels'][q] for q in ('50','95')))
    return dict(status='fail' if failures else 'within-reference-spread',failures=failures,
                twenty_percent=goal,prediction_separate=prediction,limits=LIMIT)


def validate_retained(root):
    root = Path(root); checked = []
    for p in sorted((root/'presentation').glob('cell-*')):
        final = p/'final-video-summary.json'; witness = p/'ink-signpost-presentations.csv'
        if not final.exists() or not witness.exists(): continue
        expected = json.loads(final.read_text()); ws = rows(witness)
        values = [(float(r['presented_s'])-float(r['event_s']))*1000 for r in ws]
        assert len(ws) == expected['endpoint_witnesses'], p
        for q in QUANTILES:
            assert abs(percentile(values,q)-expected['event_to_pixel_display_ms'][str(q)]) < 1e-7, (p,q)
        # Recreate old conservative exposed-board audit in normalized coordinates.
        for r in ws:
            x,y=int(r['x_px']),int(r['y_px'])
            assert 12<x<612 and 170<y<1092 and not (144<x<480 and 344<y<440) and not (36<x<588 and 972<y<1068), (p,x,y)
        frames = rows(p/'screen-frames.csv')
        for r in ws:
            assert abs(float(r['presented_s'])-float(frames[int(r['frame'])]['display_monotonic_s'])) < 1e-7
        checked.append(dict(cell=p.name,witnesses=len(ws),p95_ms=percentile(values,95),max_ms=max(values)))
    if not checked: raise ValueError('no retained evidence')
    return dict(validated_cells=len(checked),witnesses=sum(r['witnesses'] for r in checked),cells=checked,
                scope='extracted joins/distributions only; original movies/luma absent; no new presentation measurement',limits=LIMIT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command',required=True)
    p = sub.add_parser('retained');p.add_argument('root');p.add_argument('output')
    p = sub.add_parser('pixels');p.add_argument('directory')
    p = sub.add_parser('summarize');p.add_argument('directory')
    p = sub.add_parser('freeze');p.add_argument('output');p.add_argument('references',nargs='+')
    p = sub.add_parser('compare');p.add_argument('floor');p.add_argument('candidate');p.add_argument('output')
    args = parser.parse_args()
    if args.command == 'retained': dump(args.output,validate_retained(args.root))
    elif args.command == 'pixels': pixel_witnesses(args.directory)
    elif args.command == 'summarize': summarize(args.directory)
    elif args.command == 'freeze': freeze(args.references,args.output)
    else:
        result=compare(json.loads(Path(args.floor).read_text()),json.loads(Path(args.candidate).read_text()))
        dump(args.output,result)
        if result['status'] == 'fail': raise SystemExit(1)


if __name__ == '__main__': main()
