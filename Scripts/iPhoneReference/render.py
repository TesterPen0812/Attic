#!/usr/bin/env python3
"""Export only Attic's supplied HTML phone drawings. macOS, Google Chrome, Playwright, Pillow.

Usage: python3 Scripts/iPhoneReference/render.py /path/to/overnight-astra
Refuses to overwrite the evidence directory. No server, simulator, or desktop capture.
"""
import argparse
import hashlib
import io
import json
import shutil
import subprocess
import tempfile
import textwrap
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont, PngImagePlugin
from playwright.sync_api import sync_playwright

SIZE = (402, 874)
CHROME = Path('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
THEMES = ('Light', 'Dark')
WAVES = ('01-shared-chrome', '02-tasks', '03-home', '04-notes', '05-calendar',
         '06-search', '07-quick-capture', '08-canvases-draw', '09-gap')
MAIN, CAL, GAP = ('iphone-inspired', 'iphone-calendar-drafts', 'iphone-gap')

# Match exhibited stills by their source state, not by labels or thumbnail position.
MAIN_STATES = [
    (1, 'shared-chrome', dict(page='tasks')),
    (2, 'now', dict(page='tasks')), (2, 'later', dict(page='tasks', tab='later')),
    (2, 'done', dict(page='tasks', tab='done')), (2, 'tags-menu', dict(page='tasks', menu=1)),
    (2, 'work-filter', dict(page='tasks', tag='work')),
    (2, 'overdue-collapsed', dict(page='tasks', col={'overdue': 1})),
    (2, 'row-swiped', dict(page='tasks', sw='1-1')),
    (3, 'home', dict(page='home')), (3, 'scrolled', dict(page='home', y=190)),
    (3, 'tag-expanded', dict(page='home', y=290, tagOpen='launch')),
    (4, 'all-notes', dict(page='notes')), (4, 'house-filter', dict(page='notes', tag='house')),
    (4, 'editor', dict(page='notes', note=1)),
    (6, 'home-field', dict(page='home', search=1, searchFrom='field')),
    (6, 'thumb-field', dict(page='tasks', search=1, searchFrom='icon')),
    (7, 'task', dict(page='tasks', cap=1)), (7, 'note', dict(page='tasks', cap=1)),
    (8, 'canvases', dict(page='canvases')), (8, 'draw', dict(page='draw', cv=0, **{'from': 'home'})),
]
GAP_NAMES = {
    'tasks': 'task-page edit-title row-files multi-select selection-actions change-day',
    'search': 'tab-counts-canvases', 'plus': 'priority added-to-notes',
    'calendar': 'attic-event external-event away-from-today calendars-menu',
    'notes': 'board list-menu note-menu', 'editor': 'at-rest review styles highlights link find tags',
    'draw': 'canvas-menu switch-canvas shapes colours pen-widths text-sizes selection style zoom fit',
    'settings': 'home-menu settings',
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


MAIN_DRAWING = """([states, dark]) => {
    if (DARK !== dark) throw Error('Unexpected main theme');
    const tmpl = document.createElement('template');
    const norm = obj => JSON.stringify(obj, [...new Set(['page','tab','menu','tag','col','overdue','sw','y','tagOpen','note','search','searchFrom','cap','cv','from'])].sort());
    const labels = [...document.querySelectorAll('#stills .lab')].map(n=>n.textContent);
    if (STILLS.length !== labels.length) throw Error('Incomplete source stills');
    const screens = states.map(([wave,key,st]) => {
        const i = STILLS.findIndex(([,s]) => norm(s) === norm(st));
        const dynamic = ['all-notes','house-filter','canvases'].includes(key);
        if (i < 0 && !dynamic) throw Error('Still missing: '+key);
        let html = i >= 0 ? document.querySelectorAll('#stills .ph')[i].innerHTML : screen(st,DARK);
        let caption = i >= 0 ? labels[i] : ({'all-notes':'All notes, grouped list','house-filter':'All notes filtered to #house','canvases':'Canvases list'})[key];
        let recipe = i >= 0 ? 'Exhibited still '+(i+1) : 'screen('+JSON.stringify(st)+', DARK)';
        if (key==='shared-chrome') caption='Shared chrome on Tasks: tabs, Search, + and More';
        if (key==='note') {
            tmpl.innerHTML = html; tmpl.content.querySelector('.card').outerHTML = captureCard('note');
            html = tmpl.innerHTML; caption='Quick capture: Note'; recipe="Task capture shell + captureCard('note')";
        }
        if (wave===7 && key==='task') caption='Quick capture: Task';
        return {wave,key,caption,recipe,html};
    });
    if (new Set(states.map(([,key,s]) => STILLS.findIndex(([,x]) => norm(s)===norm(x))).filter(i=>i>=0)).size !== STILLS.length-1 || STILLS.filter(([,x])=>x.page==='calendar').length!==1)
        throw Error('Main sheet inventory changed; review coverage');
    tmpl.innerHTML = screen({page:'calendar',cap:1},DARK);
    return {screens, eventOverlay:['.card','.kb'].map(k=>tmpl.content.querySelector(k).outerHTML).join('')};
}"""
CAL_DRAWING = """([dark,overlay]) => {
    if (DARK!==dark || Q1[0][1].top!=='strip' || Q1[1][1].top!=='grown' || Q2[1][1].rows!=='left')
        throw Error('Calendar choices changed');
    const rows=Q2[1][1].rows;
    const result=Q1.slice(0,2).map(([,opt],i)=>({wave:5,key:i?'a2-expanded-month':'a2-week-strip',
        caption:i?'A + rows 2: expanded month':'A + rows 2: week strip',
        recipe:`phone({top:'${opt.top}', rows:'left'}, DARK)`,html:phone({top:opt.top,rows},DARK)}));
    const t=document.createElement('template');t.innerHTML=result[0].html;
    t.content.querySelector('.bot').remove(); t.content.querySelector('.sbar').insertAdjacentHTML('beforebegin',overlay);
    result.push({wave:7,key:'event',caption:'Quick capture: Event on Calendar A + rows 2',
        recipe:'Calendar strip/left shell; replace bottom chrome with inspired Event capture card and keyboard.',html:t.innerHTML});
    return result;
}"""
GAP_DRAWING = """([catalog, dark]) => {
    if (DARK!==dark) throw Error('Unexpected gap theme');
    const result=[];
    for (const group of document.querySelectorAll('#groups .grp')) {
        const id=group.id, keys=catalog[id], stills=group.querySelectorAll('.still');
        if (!keys || keys.length!==stills.length) throw Error('Gap group changed: '+id);
        stills.forEach((st,i)=>result.push({wave:9,key:id+'-'+String(i+1).padStart(2,'0')+'-'+keys[i],
            caption:st.querySelector('.lab').textContent,recipe:`#${id}, still ${i+1}`,html:st.querySelector('.ph').innerHTML}));
    }
    if (result.length!==35) throw Error('Expected 35 gap states');
    return result;
}"""
CAL_CHECK = """key => {
    const q=s=>[...document.querySelectorAll(s)];
    const rows=q('.pad .row'), tms=q('.pad .row > .tm:first-child'), days=q('.mg .md'), today=q('.md.t2 em');
    if (days.length!==(key==='a2-week-strip'?7:31) || today.length!==1 || today[0].textContent!=='28' ||
        today[0].nextElementSibling.querySelectorAll('b').length!==3 || q('.grab').length!==1 ||
        !rows.length || tms.length!==rows.length || tms.some(t=>t.getBoundingClientRect().width!==56 || getComputedStyle(t).color!==getComputedStyle(tms[0]).color) ||
        !tms.some(t=>t.textContent==='All day') || q('.pad .row .ch,.pad .row .cbar,.pad .sh2 .si').length ||
        !q('.row > .ring > .dot').length || !q('.row > .ring > svg').length || !q('.tt.past').length)
        throw Error('Calendar A + rows 2 geometry or marks do not match source');
    return {days:days.length,rows:rows.length,timeColumn:56,firstHeadingY:q('.sh2')[0].getBoundingClientRect().y};
}"""


def assert_no_traffic(log):
    data = json.loads(log.read_bytes())
    names = {v: k for k, v in data['constants']['logEventTypes'].items()}
    counts = Counter(names[e['type']] for e in data['events'])
    require(counts, 'Empty Chrome NetLog')
    # UDP connect() without send/receive is a local route lookup, not a datagram.
    bad = {k: v for k, v in counts.items() if k in ('TCP_CONNECT_ATTEMPT', 'DNS_TRANSACTION_QUERY',
           'TCP_FAST_OPEN') or any(s in k for s in ('BYTES_SENT', 'BYTES_RECEIVED', 'UDP_SEND', 'UDP_RECV', 'QUIC_SESSION_PACKET_SENT'))}
    require(not bad, f'Network activity in Chrome NetLog: {bad}')
    return {'TCP connection attempts':0, 'DNS queries':0, 'socket payload events':0}


def capture(bundle, stage, private):
    sources = {s: bundle/'ref'/'design'/s/'index.html' for s in (MAIN,CAL,GAP)}
    inputs = [*sources.values(), sources[MAIN].with_name('attic-motion.js')]
    allowed = {p.as_uri() for p in inputs}
    seen, errors = set(), []
    rows, cal = {}, {}
    log = private/'chrome-netlog.json'
    flags = ['--disable-background-networking','--disable-component-update','--disable-domain-reliability',
             '--disable-crashpad-for-testing','--disable-extensions','--disable-sync','--disable-quic',
             '--use-mock-keychain','--no-first-run','--force-webrtc-ip-handling-policy=disable_non_proxied_udp',
             '--host-resolver-rules=MAP * ~NOTFOUND','--proxy-server=http://attic-offline.invalid:9',
             '--proxy-bypass-list=<-loopback>',f'--log-net-log={log}']
    def intercept(r):
        if r.request.url in allowed:
            r.continue_()
        else:
            errors.append('Unexpected resource: '+r.request.url.split(':',1)[0]); r.abort()
    with sync_playwright() as pw:
        ctx = pw.chromium.launch_persistent_context(user_data_dir=private/'profile', executable_path=CHROME,
            headless=True,chromium_sandbox=True,offline=True,service_workers='block',accept_downloads=False,
            viewport={'width':SIZE[0],'height':SIZE[1]},device_scale_factor=1,args=flags,
            env={'HOME':str(private),'TMPDIR':str(private),'PATH':'/usr/bin:/bin'})
        try:
            version = ctx.new_cdp_session(ctx.pages[0]).send('Browser.getVersion')['product']
            ctx.route('**/*',intercept)
            pg = ctx.pages[0]; pg.on('pageerror',lambda e:errors.append(str(e)))
            pg.on('request',lambda r:seen.add(r.url))
            for theme in THEMES:
                dark = theme=='Dark'; pg.emulate_media(color_scheme=theme.lower())
                overlay = None
                for source in (MAIN,CAL,GAP):
                    pg.goto(sources[source].as_uri(),wait_until='load')
                    if source==MAIN:
                        result=pg.evaluate(MAIN_DRAWING,[MAIN_STATES,dark]); screens=result['screens']; overlay=result['eventOverlay']
                    elif source==CAL:
                        screens=pg.evaluate(CAL_DRAWING,[dark,overlay])
                    else:
                        screens=pg.evaluate(GAP_DRAWING,[{k:v.split() for k,v in GAP_NAMES.items()},dark])
                    # Remove the surrounding web gallery and thumbnail zoom. The native-size .scr
                    # is the only remaining drawing, so SVG fragment IDs resolve inside this phone.
                    for s in screens:
                        wave,key,caption=s['wave'],s['key'],s['caption']; wid=WAVES[wave-1]
                        pg.evaluate('html => {document.body.innerHTML=html;}', s['html'])
                        node=pg.locator('body > .scr'); box=node.bounding_box()
                        require(box=={'x':0,'y':0,'width':402,'height':874} and node.locator('.sbar').count()==1,
                                f'Invalid phone bounds or missing status bar: {key} {box}')
                        require(node.evaluate("(n,d)=>n.classList.contains('dk')===d && getComputedStyle(n).backgroundColor===(d?'rgb(0, 0, 0)':'rgb(255, 255, 255)')",dark), f'Wrong theme: {key}')
                        if wave==5: cal[theme,key]=pg.evaluate(CAL_CHECK,key)
                        if wave==7:
                            require(node.locator('.card .create').count()==1 and node.locator('.kb').count()==1 and
                                    node.locator('.kinds .on').count()==1, f'Capture controls missing: {key}')
                        pg.evaluate('document.fonts.ready.then(()=>true)')
                        raw=node.screenshot(animations='disabled',scale='css')
                        name=f'{wid}/reference-{key}-{theme.lower()}.png'; path=stage/name
                        path.parent.mkdir(exist_ok=True)
                        with Image.open(io.BytesIO(raw)) as im:
                            require(im.size==SIZE and im.convert('L').entropy()>0.35,f'Blank or wrong size: {name}')
                            meta=PngImagePlugin.PngInfo(); meta.add_text('Title',f'HTML REFERENCE | {wid} | {caption} | {theme}'); meta.add_text('Source',s['recipe']); im.save(path,pnginfo=meta)
                        if (wave,key) not in rows:
                            rows[wave,key]={'wave':wid,'key':key,'caption':caption,'source':source,'recipe':s['recipe'],'files':{}}
                        row=rows[wave,key]; require(theme not in row['files'],f'Duplicate: {key}/{theme}')
                        row['files'][theme]={'path':name,'sha256':sha(path.read_bytes())}
                    print(f'{theme} {source}: {len(screens)} phone PNGs',flush=True)
        finally:
            ctx.close()
    require(not errors and seen==allowed, f'Errors: {errors}; loaded {len(seen)} URLs; expected exactly four bundled files')
    for theme in THEMES:
        a,b=(cal[theme,k] for k in ('a2-week-strip','a2-expanded-month'))
        require(b['firstHeadingY']>a['firstHeadingY'], 'Expanded grid must push agenda down')
    ordered=sorted(rows.values(),key=lambda r:r['wave'])
    for row in ordered:
        files=row['files']; require(set(files)==set(THEMES),'Missing theme pair')
        with Image.open(stage/files['Light']['path']) as a, Image.open(stage/files['Dark']['path']) as b:
            require(ImageChops.difference(a.convert('RGB'),b.convert('RGB')).getbbox(),f'Identical theme pair: {row["key"]}')
    return ordered, {'chrome':version,'network':assert_no_traffic(log),'sources':{str(p.relative_to(bundle)):sha(p.read_bytes()) for p in inputs},'calendar':{t:{k:v for (th,k),v in cal.items() if th==t} for t in THEMES}}


def make_sheets(stage, rows):
    """Review thumbnails are explicitly separate from the 1:1 phone PNGs."""
    dest=stage/'overviews'; dest.mkdir()
    fonts=Path('/System/Library/Fonts/Supplemental')
    normal=ImageFont.truetype(str(fonts/'Arial.ttf'),14)
    bold=ImageFont.truetype(str(fonts/'Arial Bold.ttf'),19)
    sheets={}
    for wave in WAVES:
        states=[r for r in rows if r['wave']==wave]; sheets[wave]={}
        for theme in THEMES:
            dark=theme=='Dark'; fg='#fafafa' if dark else '#16181b'; bg='#22252a' if dark else '#e8e9ed'
            w,h=201,437; cols=min(5,len(states)); pad=14; cellw=w+pad; cellh=h+70
            title=f'{wave.replace("-"," ").title()}  /  {theme}'
            width=max(pad+cols*cellw, 2*pad+bold.getbbox(title)[2])
            board=Image.new('RGB',(width,65+((len(states)+cols-1)//cols)*cellh),bg)
            draw=ImageDraw.Draw(board); draw.text((pad,9),title,font=bold,fill=fg)
            draw.text((pad,37),'HTML reference  ·  1:2 index',font=normal,fill=fg)
            for i,r in enumerate(states):
                x=pad+i%cols*cellw; y=63+i//cols*cellh
                with Image.open(stage/r['files'][theme]['path']) as im:
                    board.paste(im.convert('RGB').resize((w,h),Image.Resampling.LANCZOS),(x,y))
                short=r['key'].replace('-',' '); label=f'{i+1:02}   {short}'
                for j,line in enumerate(textwrap.wrap(label,width=25)):
                    draw.text((x,y+h+7+16*j),line,font=normal,fill=fg)
            rel=f'overviews/{wave}-reference-{theme.lower()}.png'; board.save(stage/rel)
            sheets[wave][theme]={'path':rel,'sha256':sha((stage/rel).read_bytes())}
    return sheets


def manifests(stage, rows, audit, sheets):
    names={'01-shared-chrome':'Shared chrome','02-tasks':'Tasks','03-home':'Home','04-notes':'Notes list and editor',
           '05-calendar':'Calendar A + rows 2','06-search':'Search','07-quick-capture':'+ capture',
           '08-canvases-draw':'Canvases and Draw','09-gap':'Gap sheet — all eight source groups'}
    audit.update({'evidence':'HTML drawing reference only; not running-app evidence','renderedUTC':datetime.now(timezone.utc).isoformat(),
         'phoneLogicalSize':list(SIZE),'pngPixelSize':list(SIZE),'deviceScaleFactor':1,'states':rows,'overviews':sheets})
    (stage/'manifest.json').write_text(json.dumps(audit,indent=2,ensure_ascii=False)+'\n')
    out=['# Attic iPhone · drawing references', '',
         f'**{len(rows)} states · {len(rows)*2} full-size PNGs · 9 waves · 18 overview PNGs.** Each phone image is 402 × 874 pixels at 1×: one CSS pixel per logical point. The overviews show phones at half size; use a full-size PNG for alignment.', '',
         '**Evidence type: HTML design references only.** No app was built or launched. These are not Simulator, device, or Mac screen captures, and are not evidence that a wave passed. The status bar, keyboard, and example content are part of the drawing.', '',
         '## Reading the evidence','',
         '- **Calendar:** The two A drawings use the default rows; the rows-2 example uses a different top. The two Calendar exports use the Calendar draft’s own `phone` function with `strip` or `grown` from Q1 and `left` from Q2. Both retain the grab bar, number-only today circle and dots below it, fixed 56-point grey time column, event dots, task rings and all-day label. The main drawing’s older Calendar is superseded. These are endpoint stills, not proof of the pull gesture.',
         '- **Gap:** All 35 exhibited stills are included in source order. The bundle identifies them as drawn by Claude (Opus), not yet reviewed by the owner. “Back to the same tab and scroll position” and the task-note “Remove from Tasks” wording are specified in prose; there is no separate source still for either.',
         '- **Main:** All 15 non-superseded main-sheet stills are represented. The shared chrome deliberately repeats Tasks Now. All notes, the filtered notes list and Canvases use the drawing’s own page renderer. Note capture uses its Note card in the exhibited capture shell. Event capture uses the inspired drawing’s Event card and keyboard on the accepted Calendar week/rows-2 background. These compositions are indexed below.', '',
         f'**Method:** {audit["chrome"]}, local headless process, new temporary profile, pipe transport, offline context, blocked service workers, exact four-file allowlist. Native `.scr` only; thumbnail scaling, gallery frame, shadow and web captions are excluded. Entry animations finish before capture. Chrome NetLog recorded no TCP connection attempts, DNS queries, or socket payload events. [Source, recipe, geometry and SHA-256 inventory](manifest.json).', '',
         '## Wave index','','| Wave | States | Light overview | Dark overview |','|---|---:|---|---|']
    def link(entry, title):
        return f'[{title}]({entry["path"]})'
    for wave in WAVES:
        out.append('| {} · {} | {} | {} | {} |'.format(wave[:2],names[wave],sum(r['wave']==wave for r in rows),
            link(sheets[wave]['Light'],'Light'),link(sheets[wave]['Dark'],'Dark')))
    for wave in WAVES:
        out+=['',f'## {wave[:2]} · {names[wave]}','','| State (source caption) | Full-size Light | Full-size Dark |','|---|---|---|']
        for i,r in enumerate((r for r in rows if r['wave']==wave),1):
            out.append('| {:02} · {} | {} | {} |'.format(i,r['caption'].replace('|','\\|'),link(r['files']['Light'],'Light PNG'),link(r['files']['Dark'],'Dark PNG')))
    (stage/'MANIFEST.md').write_text('\n'.join(out)+'\n')


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('bundle',type=Path); args=p.parse_args()
    bundle=args.bundle.resolve(strict=True); out=bundle/'run/sheets/reference'
    require(out.resolve()==out and not out.exists(),'Output must be an unoccupied run/sheets/reference path')
    require(CHROME.is_file(),'Local Google Chrome is required')
    private=Path(tempfile.mkdtemp(prefix='attic-iphone-html-')); stage=private/'evidence'; stage.mkdir()
    try:
        rows,audit=capture(bundle,stage,private)
        require(len(rows)==58 and len(list(stage.glob('*/*.png')))==116,'Unexpected phone inventory')
        sheets=make_sheets(stage,rows); manifests(stage,rows,audit,sheets)
        require(len(list(stage.rglob('*.png')))==134,'Unexpected final PNG inventory')
        # Reserve a new directory exclusively. Never replace existing or another agent's files.
        out.mkdir()
        for f in sorted(stage.iterdir(),key=lambda f:f.name=='MANIFEST.md'):
            shutil.move(str(f),str(out/f.name))
        print(f'Wrote {len(rows)*2} phones and 18 overviews: {out}',flush=True)
    finally:
        # This profile and log were created by this invocation; never touch any real profile.
        subprocess.run(['/usr/bin/trash',str(private)],check=True)


if __name__=='__main__':
    main()
