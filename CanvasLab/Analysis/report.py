#!/usr/bin/env python3
"""Summarize a completed later session without pooling C3 into C1/C2."""
import argparse
import json
from pathlib import Path
from statistics import median
import analyze


def build(root):
    root=Path(root);floor=json.loads((root/'frozen-ceilings.json').read_text())
    verdict=json.loads((root/'session-verdict.json').read_text())
    result={'limits':analyze.LIMIT,'session':verdict,'nonpredictive':[],'prediction':[],'controls':[]}
    for glass in ('off','100','35'):
        mode_rows={}
        for mode in ('c1','c2','c3'):
            paths=[root/f'g{glass}-r{i}-{mode}' for i in range(3)]
            summaries=[json.loads((p/'summary.json').read_text()) for p in paths]
            comparisons=[analyze.compare(floor,s) for s in summaries]
            row=dict(mode=mode,glass=glass,repeats=3,limits=analyze.LIMIT,
                twenty_percent=mode!='c3' and verdict['status']!='inconclusive' and all(c['twenty_percent'] for c in comparisons),
                comparisons=comparisons,counts=[{k:s[k] for k in ('posted','delivered','accepted','witnesses','witness_coverage','complete_frames','distinct_complete_fps')} for s in summaries],
                metrics={metric:{q:[s['metrics'][metric][q] for s in summaries] for q in map(str,analyze.QUANTILES)} for metric in summaries[0]['metrics']},
                costs=[s.get('costs') for s in summaries])
            mode_rows[mode]=row
            result['prediction' if mode=='c3' else 'nonpredictive'].append(row)
        predictions=[]
        for i in range(3): predictions.extend(analyze.rows(root/f'g{glass}-r{i}-c3'/'prediction.csv'))
        typical=median(float(r['error_px']) for r in predictions) if predictions else None
        mode_rows['c3']['appears_earlier_than_C1_ms']=[a-b for a,b in zip(mode_rows['c1']['metrics']['event_pixels']['50'],mode_rows['c3']['metrics']['event_pixels']['50'])]
        mode_rows['c3']['next_actual_prediction_error_px']=analyze.dist([float(r['error_px']) for r in predictions]) if predictions else None
        turns=[float(r['overshoot_px']) for r in predictions if float(r.get('turn_degrees',0))>=45]
        mode_rows['c3']['sharp_turn_overshoot_px']=analyze.dist(turns) if turns else None
        mode_rows['c3']['interpretation']=f'Appears earlier values are signed C1 minus C3 captured endpoint medians; next-actual typical prediction error {typical} px; never counts toward 20%.'
    for p in sorted(root.glob('transition-*')):
        summary=json.loads((p/'summary.json').read_text());workers=analyze.rows(p/'workers.csv')
        starts={};spans=[]
        for r in workers:
            token=r['generation']
            if r['kind'] in ('worker_start','sync_start'): starts[token]=float(r['time_s'])
            elif r['kind'] in ('worker_end','cancelled','sync_end') and token in starts:
                start=starts.pop(token)
                spans.append(dict(kind=r['kind'],start_s=start,end_s=float(r['time_s']),ms=(float(r['time_s'])-start)*1000,is_main=r['is_main']))
        posted={r['sequence']:r for r in analyze.rows(p/'driver.csv')}
        downs=[dict(sequence=r['sequence'],post_handler_ms=(float(r['handler_s'])-float(posted[r['driver_sequence']]['post_s']))*1000,
                    event_handler_ms=(float(r['handler_s'])-float(r['event_monotonic_s']))*1000)
               for r in analyze.rows(p/'events.csv') if r['type']=='1']
        result['controls'].append(dict(cell=p.name,valid=summary['valid'],pointer_downs=downs,raster_spans=spans,
            cancellations=sum(r['kind']=='cancelled' for r in workers),stale_discards=sum(r['kind']=='stale' for r in workers),
            max_pending=max((int(r.get('queue_depth') or 0) for r in workers),default=0),costs=summary.get('costs'),limits=analyze.LIMIT))
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('session');a=p.parse_args()
    analyze.dump(Path(a.session)/'measurement-report.json',build(a.session))
