#!/usr/bin/env python3
"""Later Pro-only screen session. --plan is headless; --allow-screen is explicit.
No SSH, no Air, no system-settings changes, no permission prompts.
"""
import argparse
import csv
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import statistics
import subprocess
import threading
import time
import analyze

ROOT=Path(__file__).resolve().parents[2]
PRODUCTS=ROOT/'.build/dd-canvas-lab/Build/Products/Local'
BUNDLE='com.taha.Attic.lab.canvas-canvaslab'


def schedule():
    result=[]
    for i in range(3): result.append(dict(name=f'floor-{i}',mode='reference',glass='off',seconds=10))
    # Shared bracketing references: R C1 R C2 R C3 R, repeated thrice per glass.
    for glass in ('off','100','35'):
        for repeat in range(3):
            result.append(dict(name=f'g{glass}-r{repeat}-ref0',mode='reference',glass='off',seconds=10))
            for i,mode in enumerate(('c1','c2','c3'),1):
                result.append(dict(name=f'g{glass}-r{repeat}-{mode}',mode=mode,glass=glass,seconds=10))
                result.append(dict(name=f'g{glass}-r{repeat}-ref{i}',mode='reference',glass='off',seconds=10))
    # Same input after pan/zoom, both controls, plus long strokes.
    for mode in ('reference','c1','c2','c3'):
        result.append(dict(name=f'long-{mode}',mode=mode,glass='off',seconds=30))
    for mode in ('reference','c1','c2'):
        for sync in (False,True):
            result.append(dict(name=f'transition-{mode}-'+('sync' if sync else 'async'),mode=mode,glass='off',seconds=5,transitions=True,sync=sync))
    return result


def wait_file(path, process, seconds=20):
    deadline=time.monotonic()+seconds
    while not path.exists():
        if process.poll() is not None: raise RuntimeError(f'{process.args[0]} exited {process.returncode}; see cell log')
        if time.monotonic()>deadline: raise TimeoutError(str(path))
        time.sleep(0.05)


def gpu_proxy():
    try:
        tree=plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg','-r','-c','IOAccelerator','-a'],timeout=2))
        found=[]
        def visit(node):
            if isinstance(node,dict):
                stats=node.get('PerformanceStatistics',{})
                for key,value in stats.items():
                    if 'device utilization' in key.lower() and isinstance(value,(int,float)): found.append(value)
                for value in node.values(): visit(value)
            elif isinstance(node,list):
                for value in node: visit(value)
        visit(tree)
        return max(found) if found else None
    except (subprocess.SubprocessError,ValueError): return None


def cpu_seconds(value):
    days, clock = (value.split('-',1) if '-' in value else ('0',value))
    result=0.0
    for part in clock.split(':'): result=result*60+float(part)
    return float(days)*86400+result


def sample_costs(pid, path, stop):
    ws=subprocess.check_output(['/usr/bin/pgrep','-x','WindowServer'],text=True).split()[0]
    with path.open('w',newline='') as f:
        writer=csv.writer(f);writer.writerow(['time_s','app_cpu_pct','app_rss_kib','ws_cpu_pct','ws_rss_kib','device_gpu_proxy_pct'])
        previous={}
        while not stop.is_set():
            data={};now=time.monotonic()
            output=subprocess.run(['/bin/ps','-p',f'{pid},{ws}','-o','pid=,time=,rss='],text=True,capture_output=True,check=False).stdout
            for line in output.splitlines():
                parts=line.split()
                if len(parts)==3: data[parts[0]]=(cpu_seconds(parts[1]),int(parts[2]))
            if all(key in data and key in previous for key in (str(pid),ws)):
                elapsed=now-previous_time
                app_cpu=(data[str(pid)][0]-previous[str(pid)][0])/elapsed*100
                ws_cpu=(data[ws][0]-previous[ws][0])/elapsed*100
                writer.writerow([now,app_cpu,data[str(pid)][1],ws_cpu,data[ws][1],gpu_proxy()]);f.flush()
            previous=data;previous_time=now
            stop.wait(0.5)


def cost_summary(path):
    data=analyze.rows(path)
    if len(data)<2: raise ValueError('missing cost samples')
    result={}
    for field in ('app_cpu_pct','app_rss_kib','ws_cpu_pct','ws_rss_kib','device_gpu_proxy_pct'):
        values=[float(r[field]) for r in data if r[field]]
        result[field]=dict(mean=statistics.mean(values),max=max(values),samples=len(values)) if values else None
    result['limits']='ps cumulative CPU deltas every 0.5s; sampled RSS, not allocation peak; GPU is device-wide proxy, never app GPU time/uploads'
    return result


def run_cell(cell, output, env):
    p=output/cell['name'];p.mkdir()
    app=PRODUCTS/'CanvasLab.app';executable=app/'Contents/MacOS/CanvasLab'
    processes=[];stop=threading.Event();sampler=None
    with (p/'process.log').open('w') as log:
        try:
            command=[str(executable),'--allow-screen','--mode',cell['mode'],'--glass',cell['glass'],'--output',str(p)]
            if cell.get('sync'): command.append('--sync-reproducer')
            lab=subprocess.Popen(command,env=env,stdout=log,stderr=log);processes.append(lab)
            wait_file(p/'app-ready.txt',lab)
            capture_seconds=cell['seconds']+3
            recorder=subprocess.Popen([str(PRODUCTS/'CanvasLabRecorder'),'--allow-capture',str(lab.pid),str(p),str(capture_seconds),'120'],env=env,stdout=log,stderr=log)
            processes.append(recorder);wait_file(p/'recording-ready.txt',recorder)
            # A full pre-input baseline, captured with identical settings.
            time.sleep(1)
            sampler=threading.Thread(target=sample_costs,args=(lab.pid,p/'costs.csv',stop));sampler.start()
            driver=[str(PRODUCTS/'CanvasLabDriver'),'--allow-post','--pid',str(lab.pid),'--app',str(app),
                    '--output',str(p/'driver.csv'),'--seconds',str(cell['seconds'])]
            if cell.get('transitions'): driver.append('--transitions')
            subprocess.run(driver,env=env,stdout=log,stderr=log,check=True,timeout=cell['seconds']+20)
            recorder.wait(timeout=capture_seconds+30)
            if recorder.returncode: raise RuntimeError(f'capture failed {recorder.returncode}')
        finally:
            stop.set()
            if sampler: sampler.join(timeout=5)
            # Quit only our exact lab bundle, never an Attic identity/pattern.
            try:
                if processes and processes[0].poll() is None:
                    subprocess.run([str(PRODUCTS/'CanvasLabDriver'),'--quit-owned','--pid',str(processes[0].pid),
                                    '--app',str(app)],env=env,check=True,timeout=10,stdout=log,stderr=log)
                    processes[0].wait(timeout=10)
            finally:
                # Recorder cleanup still runs if app termination fails/refuses.
                for process in processes[1:]:
                    if process.poll() is None: process.terminate();process.wait(timeout=5)
    summary=analyze.summarize(p,handler_only=True) if cell.get('transitions') else analyze.pixel_witnesses(p)
    summary['costs']=cost_summary(p/'costs.csv')
    analyze.dump(p/'summary.json',summary)
    # Retain raw recordings until the later operator has checked witnesses.
    return summary


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan',action='store_true')
    parser.add_argument('--allow-screen',action='store_true')
    parser.add_argument('--output',type=Path)
    args=parser.parse_args();cells=schedule()
    if args.plan:
        print(json.dumps(dict(cells=len(cells),input_seconds=sum(c['seconds'] for c in cells),
            capture_seconds=sum(c['seconds']+3 for c in cells),schedule=cells),indent=2));return
    if not args.allow_screen or not args.output: parser.error('--allow-screen --output NEW_DIRECTORY required')
    if subprocess.check_output(['git','branch','--show-current'],cwd=ROOT,text=True).strip() != 'phase-3/restart': raise RuntimeError('wrong branch')
    env={k:os.environ[k] for k in ('PATH','HOME','TMPDIR','__CF_USER_TEXT_ENCODING') if k in os.environ}
    with open('/tmp/attic-screen.lock','a+') as lease:
        fcntl.lockf(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if __import__('shutil').disk_usage(args.output.parent if args.output.parent.exists() else ROOT).free < 80*1024**3:
            raise RuntimeError('need 80 GiB free for retained raw captures; do not delete owner data')
        args.output.mkdir(parents=True,exist_ok=False)
        output=args.output.resolve()
        executable=PRODUCTS/'CanvasLab.app/Contents/MacOS/CanvasLab'
        analyze.dump(output/'session.json',dict(branch='phase-3/restart',commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            executable=str(executable),sha256=analyze.digest(executable),bundle=BUNDLE,plan=cells,
            limits=analyze.LIMIT,display='Pro built-in, requested 120 Hz; grid verified from capture; no Air'))
        refs=[];floor=None;comparisons=[]
        for cell in cells:
            print(cell['name'],flush=True)
            summary=run_cell(cell,output,env)
            if cell['name'].startswith('floor-'):
                refs.append(output/cell['name']/'summary.json')
                if len(refs)==3:
                    floor=analyze.freeze(refs,output/'frozen-ceilings.json')
                    if not floor['stable']: raise RuntimeError('unstable references: inconclusive; do not evaluate candidates')
            elif not cell.get('transitions') and not cell['name'].startswith('long-'):
                result=analyze.compare(floor,summary);result['cell']=cell['name'];comparisons.append(result)
                analyze.dump(output/cell['name']/'comparison.json',result)
        analyze.dump(output/'comparisons.json',comparisons)
        # A drifting bracketing reference invalidates the session, without ever
        # recomputing the frozen threshold from candidates or later references.
        drift=any(r['status'] != 'within-reference-spread' for r in comparisons if '-ref' in r['cell'])
        analyze.dump(output/'session-verdict.json',dict(status='inconclusive' if drift else 'analyzed',
            reason='bracketing reference drift' if drift else 'inspect candidate failures and separate C3 report',limits=analyze.LIMIT))


if __name__=='__main__': main()
