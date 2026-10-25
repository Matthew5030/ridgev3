import hashlib,json,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
import publish_uk_ground_colour as publisher
from pack_sections import raw

def asset(name,data):return dict(file=name,byteCount=len(data),sha256=hashlib.sha256(data).hexdigest())

class PublicationTests(unittest.TestCase):
    def setup_tree(self,root):
        world=root/'live';stage=root/'stage';backup=root/'backup';world.mkdir();stage.mkdir()
        old_sources=[];new_sources=[];results=[]
        for name in ['world-a','world-b']:
            live=world/'sources'/name;prepared=stage/'sources'/name;live.mkdir(parents=True);prepared.mkdir(parents=True)
            before=dict(id=name,bounds={},columns=1,rows=1,places=[],overview={},graph={},tiles=[dict(id='tile',map=asset('old.map',b'old'))])
            after=dict(before);after['tiles']=[dict(id='tile',map=asset('new.map',name.encode()))]
            (live/'old.map').write_bytes(b'old');(live/'world.json').write_bytes(raw(before))
            (prepared/'world.before.json').write_bytes(raw(before));(prepared/'world.json').write_bytes(raw(after));(prepared/'new.map').write_bytes(name.encode());(prepared/'new.ridgepack').write_bytes(b'pack-'+name.encode())
            (prepared/'ground-colour-provenance.json').write_bytes(b'{}');(prepared/'section-pack-v1.json').write_bytes(b'{}')
            descriptor=dict(id=name,path=f'sources/{name}/world.json',pack=asset('new.ridgepack',b'pack-'+name.encode()))
            old_sources.append(dict(id=name,path=descriptor['path']));new_sources.append(descriptor)
            results.append(dict(sourceID=name,inputManifestSHA256=hashlib.sha256(raw(before)).hexdigest(),tiles=1,tilesWithColour=1,usablePercent=99,pack=descriptor['pack']))
        old=raw(dict(sources=old_sources,regionArchives=[]));new=raw(dict(sources=new_sources,regionArchives=[]))
        (world/'catalog.json').write_bytes(old);(stage/'catalog.before.json').write_bytes(old);(stage/'catalog.json').write_bytes(new);(stage/'results.json').write_bytes(raw(results))
        return world,stage,backup,old
    def test_interrupted_copy_resumes_and_only_then_publishes(self):
        with tempfile.TemporaryDirectory() as directory:
            world,stage,backup,old=self.setup_tree(Path(directory));original_copy=publisher.copy_asset
            def interrupted(source,destination,description):
                if destination.parent.name=='world-b':raise RuntimeError('simulated interruption')
                return original_copy(source,destination,description)
            with patch.object(publisher,'copy_asset',side_effect=interrupted):
                with self.assertRaises(RuntimeError):publisher.publish(world,stage,backup,True)
            self.assertEqual((world/'catalog.json').read_bytes(),old)
            for name in ['world-a','world-b']:
                self.assertEqual((world/'sources'/name/'world.json').read_bytes(),(stage/'sources'/name/'world.before.json').read_bytes())
            publisher.publish(world,stage,backup,True)
            self.assertEqual((world/'catalog.json').read_bytes(),(stage/'catalog.json').read_bytes())
            for name in ['world-a','world-b']:
                self.assertEqual((world/'sources'/name/'world.json').read_bytes(),(stage/'sources'/name/'world.json').read_bytes())
                self.assertTrue((world/'sources'/name/'old.map').exists())
            publisher.publish(world,stage,backup,True)  # completed run is idempotent
    def test_damaged_asset_never_replaces_live_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            world,stage,backup,old=self.setup_tree(Path(directory))
            (stage/'sources/world-a/new.map').write_bytes(b'damaged')
            with self.assertRaises(ValueError):publisher.publish(world,stage,backup,True)
            self.assertEqual((world/'catalog.json').read_bytes(),old)
            self.assertFalse((world/'sources/world-a/new.map').exists())
    def test_existing_immutable_asset_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'in';target=root/'out';source.write_bytes(b'new');target.write_bytes(b'old')
            with self.assertRaises(ValueError):publisher.copy_asset(source,target,asset('out',b'new'))
            self.assertEqual(target.read_bytes(),b'old')

if __name__=='__main__':unittest.main()
