import json, tempfile, unittest, os, time, struct, subprocess, sys, concurrent.futures
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import patch
import batch_world as batch

def fork_probe(job):
    time.sleep(.03)
    return os.getpid(), job


class BatchTests(unittest.TestCase):
    def test_region_slots_respect_cpu_and_memory_reservations(self):
        gib=1024**3
        self.assertEqual(batch.region_slots(6,2,12,24*gib,gib),6)
        self.assertEqual(batch.region_slots(12,2,12,24*gib,gib),6)
        self.assertEqual(batch.region_slots(6,2,4,24*gib,gib),2)
        self.assertEqual(batch.region_slots(6,2,12,24*gib,6*gib),1)
        self.assertEqual(batch.region_slots(1,2,12,24*gib,gib),1)

    def test_regions_use_independent_processes_and_join_after_completion(self):
        with patch.object(batch,'region_result',fork_probe):
            results=list(batch.region_results(list(range(9)),3))
        self.assertEqual(sorted(job for _,job in results),list(range(9)))
        pids={pid for pid,_ in results}
        self.assertEqual(len(pids),3)
        self.assertNotIn(os.getpid(),pids)
        for pid in pids:
            with self.assertRaises(ProcessLookupError):os.kill(pid,0)

    def test_closing_region_iterator_stops_unpublished_work(self):
        with patch.object(batch,'region_result',fork_probe):
            results=batch.region_results(list(range(30)),3)
            pid,_=next(results)
            results.close()
        with self.assertRaises(ProcessLookupError):os.kill(pid,0)

    def test_region_deadline_and_failure_are_reported_without_publication(self):
        with tempfile.TemporaryDirectory() as d:
            a=SimpleNamespace(deadline_unix=1,reserve_gib=0,output=Path(d))
            context=(a,None,dict(id='fixture'),None,None,None,None,None,None)
            with patch.object(batch,'REGION_CONTEXT',context):
                self.assertEqual(batch.region_result((0,0,[])),('world-fixture-c00-r00',None,'paused-time-limit'))
                a.deadline_unix=None
                with patch.object(batch,'source',side_effect=ValueError('broken source')):
                    key,entry,error=batch.region_result((16,0,[]))
                self.assertEqual(key,'world-fixture-c16-r00')
                self.assertIsNone(entry)
                self.assertIn('broken source',error)
                self.assertFalse((Path(d)/'catalog.json').exists())

    def test_grid_partition_alignment(self):
        bounds=dict(minLongitude=-5,maxLongitude=-4,minLatitude=52,maxLatitude=53)
        for y in range(48):
            for x in range(48):
                c=dict(id=f'z10-x500-y333-c{x//4:02d}-{y//4:02d}-p{x%4:02d}-{y%4:02d}')
                self.assertEqual(batch.cell(c),(x,y))
                parent=batch.subbounds(bounds,x//16*16,y//16*16,16)
                child=batch.subbounds(bounds,x,y,1)
                self.assertTrue(batch.contains(parent,child['minLongitude'],child['maxLatitude']))
    def test_verified_read_rejects_corruption(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'asset';p.write_bytes(b'original')
            self.assertEqual(batch.read_verified(p,batch.sha(b'original'),8),b'original')
            p.write_bytes(b'changed')
            with self.assertRaises(ValueError):batch.read_verified(p,batch.sha(b'original'))
    def test_unavailable_file_never_opened(self):
        with patch.object(batch,'resident',return_value=False):
            with self.assertRaises(FileNotFoundError):batch.read_verified(Path('/not-downloaded'),'',0)
    def test_atomic_replacement_preserves_parseable_json(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'status.json'
            batch.atomic(p,batch.rawjson(dict(ready=0)))
            batch.atomic(p,batch.rawjson(dict(ready=1)))
            self.assertEqual(json.loads(p.read_bytes()),dict(ready=1))
            self.assertFalse(p.with_name('status.json.tmp').exists())

class CodecLibraryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary=tempfile.TemporaryDirectory()
        cls.root=Path(cls.temporary.name)
        source=Path(batch.__file__).resolve().parents[1]/'adaptive_terrain/compact_mesh.cpp'
        flags=['-dynamiclib'] if sys.platform=='darwin' else ['-shared','-fPIC']
        suffix='dylib' if sys.platform=='darwin' else 'so'
        subprocess.run(['clang++','-O2','-std=c++17',*flags,str(source),'-o',str(cls.root/('libridge_compact_mesh.'+suffix))],check=True)
        subprocess.run(['clang++','-O2','-std=c++17',str(source),'-o',str(cls.root/'compact_mesh')],check=True)
        # Canonical unsplit RTIN, independently specified RME1 binary fixture.
        cls.mesh=struct.pack('<4s4I2f',b'RME1',4,2,2,513,.1,0)
        cls.mesh+=b''.join(struct.pack('<HHh',x,y,100) for x,y in [(0,0),(512,512),(512,0),(0,512)])
        cls.mesh+=struct.pack('<6H',0,1,2,1,0,3)

    @classmethod
    def tearDownClass(cls):
        batch.codec.cache_clear()
        cls.temporary.cleanup()

    def test_library_matches_cli_and_supports_concurrent_round_trips(self):
        (self.root/'mesh').write_bytes(self.mesh)
        subprocess.run([str(self.root/'compact_mesh'),'encode',str(self.root/'mesh'),str(self.root/'top')],check=True,stdout=subprocess.DEVNULL)
        expected=(self.root/'top').read_bytes()
        native=batch.codec(self.root)
        def check(_):
            encoded=native.encode(self.mesh)
            return encoded,native.decode(encoded)
        with concurrent.futures.ThreadPoolExecutor(8) as pool:
            for encoded,decoded in pool.map(check,range(32)):
                self.assertEqual(encoded,expected)
                self.assertEqual(decoded,self.mesh)

    def test_library_rejects_truncated_topology(self):
        native=batch.codec(self.root)
        encoded=native.encode(self.mesh)
        with self.assertRaises(ValueError):native.decode(encoded[:-1])


if __name__=='__main__':unittest.main()
