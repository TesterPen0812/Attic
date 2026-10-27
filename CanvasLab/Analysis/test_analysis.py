import copy
import csv
import json
from pathlib import Path
import tempfile
import unittest
import analyze


class AnalysisTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fixture(self, name='reference', delay=0, drop_event=False, drop_frame=False):
        p=self.root/name;p.mkdir()
        driver=[];events=[];witnesses=[]
        frames=[dict(index=i,display_monotonic_s=100+i/120,video_appended='true') for i in range(140)]
        for i in range(120):
            t=100+i/120
            driver.append(dict(sequence=str(i+1),type='6',event_monotonic_s=t,post_s=t))
            events.append(dict(sequence=str(i+1),driver_sequence=str(i+1),event_monotonic_s=t,
                handler_s=t+0.001+delay,overlay_s=t+0.002+delay,ca_commit_submit_s=t+0.003+delay,type='6'))
            frame=i+3+round(delay*120)
            witnesses.append(dict(sequence=str(i+1),frame=frame,presented_s=frames[frame]['display_monotonic_s']))
        if drop_event:
            events.pop(60);witnesses.pop(60)
        if drop_frame: frames.pop(10)
        for filename,records in [('driver.csv',driver),('events.csv',events),('screen-frames.csv',frames),('ink-presentations.csv',witnesses)]:
            with (p/filename).open('w',newline='') as f:
                writer=csv.DictWriter(f,fieldnames=records[0]);writer.writeheader();writer.writerows(records)
        (p/'settings.json').write_text(json.dumps(dict(mode='reference' if name.startswith('reference') else 'c1')))
        return p

    def floor(self):
        paths=[]
        for i in range(3):
            p=self.fixture(f'reference{i}');analyze.summarize(p);paths.append(p/'summary.json')
        return analyze.freeze(paths,self.root/'frozen.json')

    def testCleanPassAndInjectedDelayFailsFrozenGate(self):
        floor=self.floor()
        clean=analyze.summarize(self.fixture('c1'))
        self.assertTrue(clean['valid'])
        self.assertEqual(analyze.compare(floor,clean)['status'],'within-reference-spread')
        delayed=analyze.summarize(self.fixture('delayed',delay=0.1))
        self.assertTrue(delayed['valid'])
        self.assertEqual(analyze.compare(floor,delayed)['status'],'fail')

    def testDroppedAcceptedSamplesFail(self):
        floor=self.floor();dropped=analyze.summarize(self.fixture('dropped',drop_event=True))
        self.assertFalse(dropped['valid'])
        self.assertIn('posted/delivered sample loss or unmatched sample',dropped['problems'])
        self.assertEqual(analyze.compare(floor,dropped)['status'],'fail')

    def testDroppedCaptureSamplesFail(self):
        p=self.fixture('droppedframes',drop_frame=True)
        with self.assertRaisesRegex(ValueError,'timestamp mismatch'):
            analyze.summarize(p)

    def testFreezeRejectsCandidatesAndIsImmutable(self):
        floor=self.floor()
        with self.assertRaises(FileExistsError):
            analyze.freeze([self.root/f'reference{i}'/'summary.json' for i in range(3)],self.root/'frozen.json')
        candidate=analyze.summarize(self.fixture('c1'))
        (self.root/'candidate.json').write_text(json.dumps(candidate))
        with self.assertRaisesRegex(ValueError,'nonreference'):
            analyze.freeze([self.root/'candidate.json']*3,self.root/'bad.json')
        self.assertTrue(floor['stable'])

    def testUnstableReferenceIsInconclusive(self):
        floor=self.floor();floor['stable']=False
        self.assertEqual(analyze.compare(floor,analyze.summarize(self.fixture('c1')))['status'],'inconclusive')

    def testPredictionNeverCountsTowardGoal(self):
        floor=self.floor();candidate=analyze.summarize(self.fixture('c1'));candidate['mode']='c3'
        for q in ('50','95'): candidate['metrics']['event_pixels'][q]=1
        result=analyze.compare(floor,candidate)
        self.assertFalse(result['twenty_percent']);self.assertTrue(result['prediction_separate'])

    def testNegativeWitnessCannotPass(self):
        p=self.fixture('negative');w=analyze.rows(p/'ink-presentations.csv');w[5]['frame']='0';w[5]['presented_s']='100'
        with (p/'ink-presentations.csv').open('w',newline='') as f:
            writer=csv.DictWriter(f,fieldnames=w[0]);writer.writeheader();writer.writerows(w)
        self.assertIn('negative witness latency',analyze.summarize(p)['problems'])

    def testPercentilesMatchLinearRetainedConvention(self):
        self.assertEqual(analyze.percentile([0,10,20],95),19)
        with self.assertRaises(ValueError): analyze.dist([])
        with self.assertRaises(ValueError): analyze.dist([float('nan')])



class PixelTests(unittest.TestCase):
    def testSlowStrokeExtractionAndInjectedPixelDelay(self):
        import numpy as np
        from PIL import Image, ImageDraw
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            def fixture(name,delay):
                p=root/name;p.mkdir()
                width,height,stride=640,120,640
                count=36;frame_count=count+delay+5
                canvas=Image.new('L',(width,height),255);draw=ImageDraw.Draw(canvas)
                frames=[];events=[];driver=[];chunks=[]
                for index in range(frame_count):
                    i=index-3-delay
                    if 0<=i<count:
                        point=(30+i*4,60)
                        if i: draw.line([(30+(i-1)*4,60),point],fill=0,width=4)
                    frames.append(dict(index=index,display_monotonic_s=100+index/120,width=width,height=height,stride=stride,video_appended='true'))
                    chunks.append(np.asarray(canvas).tobytes())
                for i in range(count):
                    t=100+(i+2)/120
                    events.append(dict(sequence=i+1,driver_sequence=i+1,event_monotonic_s=t,handler_s=t+0.001,overlay_s=t+0.002,ca_commit_submit_s=t+0.003,type='6'))
                    driver.append(dict(sequence=i+1,type='6',x=(30+i*4)/2,y=30,event_monotonic_s=t,post_s=t))
                for filename,data in [('events.csv',events),('driver.csv',driver),('screen-frames.csv',frames)]:
                    with (p/filename).open('w',newline='') as f:
                        writer=csv.DictWriter(f,fieldnames=data[0]);writer.writeheader();writer.writerows(data)
                (p/'gray.bin').write_bytes(b''.join(chunks))
                (p/'capture-settings.json').write_text(json.dumps(dict(window_frame_cg_pt=[0,0,320,60])))
                (p/'settings.json').write_text(json.dumps(dict(mode='reference' if name.startswith('reference') else 'c1',glass='off')))
                return p
            refs=[fixture(f'reference{i}',0) for i in range(3)]
            for p in refs:
                summary=analyze.pixel_witnesses(p)
                self.assertTrue(summary['valid'],summary['problems'])
                self.assertGreater(summary['witnesses'],20)
            floor=analyze.freeze([p/'summary.json' for p in refs],root/'floor.json')
            delayed=analyze.pixel_witnesses(fixture('delayed',12))
            self.assertEqual(analyze.compare(floor,delayed)['status'],'fail')

if __name__ == "__main__": unittest.main()
