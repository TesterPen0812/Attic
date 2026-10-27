#!/usr/bin/env python3
"""Port of scan-kdebug.py; optional exact-PID trace audit, not ink proof."""
import argparse
from collections import Counter
import json
from pathlib import Path
import xml.etree.ElementTree as E

def scan(source):
    refs={};counts=Counter();selected=[];rows=0
    for _,e in E.iterparse(source,events=['end']):
        if e.tag!='row': continue
        for n in e.iter():
            if 'id' in n.attrib: refs[n.attrib['id']]=(n.text or '',n.attrib.get('fmt',''))
        def value(n): return refs[n.attrib['ref']][0] if 'ref' in n.attrib else (n.text or '')
        cols=list(e);rows+=1
        if len(cols)==14:
            cl,sub,code,fun=[int(value(c) or 0) for c in cols[6:10]];counts[cl,sub,code]+=1
            if cl==0x31 and sub in (0xca,0xd0,0xd1):
                selected.append(dict(time_ns=int(value(cols[0])),class_id=cl,subclass=sub,code=code,function=fun,
                                     args=[int(value(c) or 0) for c in cols[10:]]))
        e.clear()
    return dict(rows=rows,selected=selected,limits='Global compositor events do not identify ink consumption; not presentation proof')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('input');p.add_argument('output');a=p.parse_args()
    # Partial XML is an error, never a silent successful partial export.
    Path(a.output).write_text(json.dumps(scan(a.input),indent=2)+'\n')
