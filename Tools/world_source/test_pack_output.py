"""External pack output retains exact bytes and resumable descriptors."""
import hashlib,tempfile,unittest
from pathlib import Path
from pack_sections import build,raw

class PackOutputTests(unittest.TestCase):
    def test_external_output_matches_original_and_resumes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);folder=root/'sources/world-test';folder.mkdir(parents=True);out=root/'external';assets=[]
            for name,data in [('overview-32m.json',b'{"heights":[1,2,3]}'),('paths-test.json',b'{"nodes":[],"edges":[]}'),('c00-r00.rat.zlib',b'opaque mesh bytes'),('c00-r00.map',b'vector bytes')]:
                (folder/name).write_bytes(data);assets.append(dict(file=name,sha256=hashlib.sha256(data).hexdigest(),byteCount=len(data)))
            manifest=dict(id='world-test',overview=assets[0],graph=assets[1],tiles=[dict(mesh=assets[2],background=assets[2],map=assets[3])])
            (folder/'world.json').write_bytes(raw(manifest));entry=dict(id='world-test',path='sources/world-test/world.json')
            original=build(root,entry);payload=(folder/original['file']).read_bytes();(folder/'section-pack-v1.json').unlink();(folder/original['file']).unlink()
            external=build(root,entry,output_folder=out)
            self.assertEqual(original,external);self.assertTrue((folder/external['file']).is_symlink());self.assertEqual((out/external['file']).read_bytes(),payload)
            self.assertEqual(build(root,entry,output_folder=out),external)

if __name__=='__main__':unittest.main()
