import gzip,hashlib,json,tempfile,unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import repair_english_border as repair
import numpy as np
from repair_english_border import native_selection,grid_key,immutable_name,sha,raw,publication_assets


class RepairTests(unittest.TestCase):
    def test_native_archive_rehydrates_and_checks_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);tile=root/'native/tiles/10/504/336';tile.mkdir(parents=True)
            data=bytes(513*513*2);archive=root/'native.bin.gz';archive.write_bytes(gzip.compress(data))
            bounds=dict(minLongitude=-3,maxLongitude=-2,minLatitude=52,maxLatitude=53)
            child=dict(id='p00-00',bounds=bounds,lods=[dict(path='precision/p00-00/lod-1m.bin',byteCount=len(data),sha256=sha(data),compressedArchive=str(archive))])
            m=dict(bounds=bounds,parents=[dict(id='c00-00',precisionChildren=[child])]);payload=raw(m)
            (tile/'manifest.json').write_bytes(payload);(tile/'COMPLETE.json').write_bytes(raw(dict(manifestSHA256=sha(payload))))
            result=native_selection(SimpleNamespace(cache=root),dict(id='z10-x504-y336'))
            self.assertEqual(result['bounds'],bounds)
            self.assertEqual(Path(result['chunks'][0]['source']).read_bytes(),data)
            archive.write_bytes(gzip.compress(b'broken'))
            with self.assertRaises(ValueError):native_selection(SimpleNamespace(cache=root),dict(id='z10-x504-y336'))

    def test_grid_neighbours_cross_parent_and_section_edges(self):
        self.assertEqual(grid_key('z10-x504-y336-c00-00-p00-00'),(504*48,336*48))
        self.assertEqual(grid_key('z10-x503-y336-c11-00-p03-00')[0]+1,grid_key('z10-x504-y336-c00-00-p00-00')[0])

    def test_immutable_staging_asset_cannot_replace_different_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);(root/'old').write_bytes(b'input');(root/'new').write_bytes(b'collision')
            with self.assertRaises(ValueError):immutable_name(root,dict(file='old',sha256=sha(b'input')),'new')
            self.assertEqual((root/'new').read_bytes(),b'collision')

    def test_identical_payloads_at_different_loose_urls_are_both_published(self):
        def asset(name):return dict(file=name,sha256='same',byteCount=4)
        m=dict(overview=asset('overview.json'),graph=asset('paths.json'),tiles=[dict(mesh=asset('a.rat.zlib'),background=asset('b.rat.zlib'),map=asset('a.map'))])
        names=publication_assets(m,dict(pack=asset('section.ridgepack')))
        self.assertEqual(set(names),{'overview.json','paths.json','a.rat.zlib','b.rat.zlib','a.map','section.ridgepack'})

    def test_incompatible_existing_survey_is_excluded_without_altering_heights(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);previous=root/'previous';(previous/'selection').mkdir(parents=True)
            tile=root/'native/tiles/10/504/336';tile.mkdir(parents=True)
            bounds=dict(minLongitude=-3,maxLongitude=-2,minLatitude=52,maxLatitude=53)
            data=bytes(513*513*2);archive=root/'native.bin.gz';archive.write_bytes(gzip.compress(data))
            child=dict(id='p00-00',bounds=bounds,lods=[dict(path='precision/p00-00/lod-1m.bin',byteCount=len(data),sha256=sha(data),compressedArchive=str(archive))])
            payload=raw(dict(bounds=bounds,parents=[dict(id='c00-00',precisionChildren=[child])]))
            (tile/'manifest.json').write_bytes(payload);(tile/'COMPLETE.json').write_bytes(raw(dict(manifestSHA256=sha(payload))))
            old=np.ones((513,513),dtype='<i2').tobytes();old_path=root/'old.bin';old_path.write_bytes(old)
            original=dict(id='z10-x504-y336-c00-00-p01-00',source=str(old_path),sourceSHA256=sha(old),sourceByteCount=len(old))
            diagonal=dict(original,id='z10-x504-y336-c00-00-p01-01')
            (previous/'selection/z10-x504-y336.json').write_bytes(raw(dict(chunks=[original,diagonal])))
            a=SimpleNamespace(cache=root,previous=previous);row=dict(id='z10-x504-y336');new=native_selection(a,row,False)
            with self.assertRaises(ValueError):repair.audit_native_seams(a,row,new)
            repair.audit_native_seams(a,row,new,exclude_incompatible=True)
            self.assertEqual(new['chunks'],[])
            self.assertEqual(old_path.read_bytes(),old)
            self.assertEqual(native_selection(a,row,False)['chunks'],[])
            rejected=json.loads((root/'seams/z10-x504-y336.excluded.json').read_bytes())
            self.assertEqual({f['contact'] for f in rejected['failures']},{'edge','corner'})


class RepairPublicationTests(unittest.TestCase):
    def fixture(self,root):
        world=root/'live';cache=root/'cache';stage=cache/'world-stage';world.mkdir();stage.mkdir(parents=True)
        def asset(name):
            data=name.encode();return dict(file=name,sha256=sha(data),byteCount=len(data))
        def tile(name):return dict(id=name,mesh=asset(name+'.rat.zlib'),background=asset(name+'.background.rat.zlib'),map=asset(name+'.map'))
        old=dict(id='world-a',tiles=[tile('old')],overview=asset('old-overview.json'),graph=asset('old-graph.json'))
        catalog_before=dict(revision='before',sources=[dict(id='world-a',path='sources/world-a/world.json',tileCount=1)])
        (world/'catalog.json').write_bytes(raw(catalog_before));live=world/'sources/world-a';live.mkdir(parents=True);(live/'world.json').write_bytes(raw(old))
        values={}
        for name,tiles in [('world-a',[tile('old'),tile('new')]),('world-b',[tile('second')])]:
            folder=stage/'sources'/name;folder.mkdir(parents=True)
            m=dict(id=name,tiles=tiles,overview=asset(name+'-overview.json'),graph=asset(name+'-graph.json'))
            entry=dict(id=name,path=f'sources/{name}/world.json',tileCount=len(tiles),pack=asset(name+'.ridgepack'));values[name]=entry
            for filename,desc in publication_assets(m,entry).items():(folder/filename).write_bytes(filename.encode())
            (folder/'world.json').write_bytes(raw(m))
            for filename in ['ground-colour-provenance.json','section-pack-v1.json']:(folder/filename).write_bytes(b'{}')
            if name=='world-a':(folder/'live-world.before.json').write_bytes(raw(old))
        target=dict(revision='after',sources=list(values.values()));(stage/'catalog.before.json').write_bytes(raw(catalog_before));(stage/'catalog.json').write_bytes(raw(target))
        return SimpleNamespace(world=world,cache=cache),stage,old,target,values

    def test_interrupted_object_copy_preserves_metadata_then_resumes(self):
        from publish_uk_ground_colour import copy_asset
        with tempfile.TemporaryDirectory() as temporary:
            a,stage,old,target,entries=self.fixture(Path(temporary));before=(a.world/'catalog.json').read_bytes()
            def interrupted(source,dest,description):
                if dest.parent.name=='world-b':raise RuntimeError('interrupted copy')
                return copy_asset(source,dest,description)
            with patch.object(repair,'finalize_catalog',return_value=(target,entries,[])):
                with patch('publish_uk_ground_colour.copy_asset',side_effect=interrupted):
                    with self.assertRaises(RuntimeError):repair.publish_repair(a)
                self.assertEqual((a.world/'catalog.json').read_bytes(),before)
                self.assertEqual(json.loads((a.world/'sources/world-a/world.json').read_bytes()),old)
                repair.publish_repair(a)
            self.assertEqual(json.loads((a.world/'catalog.json').read_bytes()),target)
            self.assertEqual(json.loads((stage/'repair-publication-report.json').read_bytes())['addedTerrainTiles'],2)

    def test_metadata_interruption_keeps_original_backup_and_tile_accounting(self):
        with tempfile.TemporaryDirectory() as temporary:
            a,stage,old,target,entries=self.fixture(Path(temporary));original_atomic=repair.atomic
            def interrupted(path,data):
                if path==a.world/'catalog.json':raise RuntimeError('interrupted catalogue switch')
                return original_atomic(path,data)
            with patch.object(repair,'finalize_catalog',return_value=(target,entries,[])):
                with patch.object(repair,'atomic',side_effect=interrupted):
                    with self.assertRaises(RuntimeError):repair.publish_repair(a)
                repair.publish_repair(a)
            backup=a.world/'terrain-repairs/2026-10-20-english-border/world-a.world.json'
            self.assertEqual(json.loads(backup.read_bytes()),old)
            self.assertEqual(json.loads((stage/'repair-publication-report.json').read_bytes())['addedTerrainTiles'],2)


if __name__=='__main__':unittest.main()
