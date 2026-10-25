import http.server,json,tempfile,threading,unittest,urllib.request
from functools import partial
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace
from standard_tracker import Tracker,Handler

class TrackerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name);self.now=1000
        self.write('plan.json',dict(newNativeCells=10,parents=[dict(id='a',sources=[dict(id='one',name='North',newCells=[0]*6),dict(id='two',name='North',newCells=[0]*2)]),dict(id='b',sources=[dict(id='three',name='South',newCells=[0]*2)])]))
        self.write('rollout-status.json',dict(state='building',updated=950));self.write('status.json',dict(failures={}))
        self.write('colour-status.json',dict(active=['a'],failures={}))
        self.write('completed/a.json',[dict(id='one',standardTileCount=6),dict(id='two',standardTileCount=2)])
        (self.root/'coloured').mkdir();self.write('world/sources/one/standard-complete.json',dict(id='one',standardTileCount=6));self.write('world/sources/one/standard-colour-complete.json',{})
        self.tracker=Tracker(self.root,clock=lambda:self.now)
    def write(self,name,value):
        p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(value))
    def test_weights_tiles_and_includes_source_progress_inside_active_batch(self):
        s=self.tracker.snapshot(force=True)
        self.assertEqual((s['terrainTiles'],s['totalTiles']),(8,10));self.assertEqual((s['terrainBatches'],s['totalBatches']),(1,2))
        self.assertEqual(s['colourTiles'],6);self.assertEqual(s['colourBatches'],0);self.assertEqual(s['packsReady'],1);self.assertFalse(s['stale'])
        self.assertEqual(s['activity'][0]['name'],'North');self.assertEqual(s['activity'][0]['ready'],1)
    def test_refresh_does_not_freshen_worker_heartbeat(self):
        self.now=2000;s=self.tracker.snapshot(force=True)
        self.assertEqual(s['observedAt'],2000);self.assertEqual(s['workerUpdatedAt'],950);self.assertTrue(s['stale'])
    def test_completed_parent_is_not_double_counted_when_active_status_lags(self):
        self.write('coloured/a.json',{})
        s=self.tracker.snapshot(force=True);self.assertEqual(s['colourTiles'],8);self.assertEqual(s['packsReady'],2);self.assertEqual(s['activity'],[])
    def test_one_bad_status_is_reported_without_hiding_other_progress(self):
        (self.root/'colour-status.json').write_text('{broken')
        s=self.tracker.snapshot(force=True);self.assertEqual(s['terrainTiles'],8);self.assertTrue(s['readErrors'])
    def test_reused_pid_does_not_falsely_report_a_running_job(self):
        (self.root/'rollout-worker.pid').write_text('123')
        with patch('standard_tracker.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout='123 Ss /usr/bin/unrelated')):
            self.assertFalse(self.tracker.snapshot(force=True)['workersAlive']['coordinator'])
        command='123 Ss python standard_rollout.py --root '+str(self.root)
        with patch('standard_tracker.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout=command)):
            self.assertTrue(self.tracker.snapshot(force=True)['workersAlive']['coordinator'])

    def test_http_snapshot_is_not_cached_and_static_study_still_works(self):
        self.write('test.json',{'ok':True})
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),partial(Handler,directory=str(self.root)));server.tracker=self.tracker
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        try:
            base='http://127.0.0.1:'+str(server.server_port)
            with urllib.request.urlopen(base+'/uk-coverage/live.json?t=1') as response:
                self.assertEqual(json.load(response)['terrainTiles'],8);self.assertIn('no-store',response.headers['Cache-Control'])
            with urllib.request.urlopen(base+'/test.json') as response:self.assertTrue(json.load(response)['ok'])
        finally:server.shutdown();server.server_close();worker.join()

if __name__=='__main__':unittest.main()
