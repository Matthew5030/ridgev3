import hashlib,json,sqlite3,subprocess,sys,tempfile,unittest
from pathlib import Path
from import_uk_sections import selection_hash

HERE=Path(__file__).resolve().parent

def sha(raw):return hashlib.sha256(raw).hexdigest()

def write(path,value):
    path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value));return path.read_bytes()


class UKImportTests(unittest.TestCase):
    def fixture(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup);root=Path(temporary.name)
        old=root/'old-build';new=root/'new-build';old_downloads=root/'old-downloads';new_downloads=root/'new-downloads';key='z10-x1-y1'
        chunk=dict(id=key+'-c00-00-p00-00',bounds={'minLongitude':0,'maxLongitude':1,'minLatitude':0,'maxLatitude':1},sourceSHA256='source')
        selection=dict(chunks=[chunk]);write(new/'selection'/f'{key}.json',selection)
        plan=dict(id='old',boundarySHA256='boundary',worldGridSHA256='world',officialSurveyCoverage={},partitions=[dict(id=key,chunkCount=1)])
        old_plan=write(old/'plan.json',plan);write(new/'plan.json',{**plan,'id':'new'})
        write(old/'build-inputs.json',dict(planSHA256=sha(old_plan),compilerSHA256='compiler'))
        manifest=write(old/'partitions'/key/'manifest.json',dict(sourceSelectionSHA256=selection_hash(selection),compilerSHA256='compiler'))
        write(old/'partitions'/key/'validation.json',dict(manifestSHA256=sha(manifest),maxSeamHeightDifferenceMetres=0))
        folder=key+'-adaptive-0p5';payload=b'unchanged verified container';path=old_downloads/folder/'terrain.ratpack';path.parent.mkdir(parents=True);path.write_bytes(payload)
        index=write(old_downloads/folder/'adaptive.json',dict(sourceManifestSHA256=sha(manifest),container=dict(path='terrain.ratpack',byteCount=len(payload),sha256=sha(payload))))
        write(old_downloads/'catalog.json',dict(id='old',partitions=[dict(id=key,path=folder+'/adaptive.json',sha256=sha(index),chunks=1,meshBytes=len(payload))]))
        write(old/'status.json',dict(partitions={key:dict(status='published')}))
        db=sqlite3.connect(old/'outer-edges.sqlite');db.execute('CREATE TABLE edges (key TEXT PRIMARY KEY,heights BLOB,firstOwner TEXT,secondOwner TEXT)');db.execute('INSERT INTO edges VALUES(?,?,?,?)',('edge',b'height',key,'unfinished'));db.commit();db.close()
        return root,old,new,old_downloads,new_downloads,key

    def run_import(self,old,new,old_downloads,new_downloads):
        return subprocess.run([sys.executable,str(HERE/'import_uk_sections.py'),'--previous-build',str(old),'--build',str(new),'--previous-downloads',str(old_downloads),'--downloads',str(new_downloads)],capture_output=True,text=True)

    def test_verified_unchanged_sections_import_and_unfinished_seams_are_dropped(self):
        root,old,new,od,nd,key=self.fixture();result=self.run_import(old,new,od,nd);self.assertEqual(result.returncode,0,result.stderr)
        d=json.loads((nd/'catalog.json').read_bytes());self.assertEqual(d['id'],'new');self.assertFalse(d['buildComplete']);self.assertEqual(len(d['partitions']),1)
        db=sqlite3.connect(new/'outer-edges.sqlite');self.assertEqual(db.execute('SELECT secondOwner FROM edges').fetchone(),(None,));db.close()
        self.assertEqual((nd/(key+'-adaptive-0p5')/'terrain.ratpack').read_bytes(),b'unchanged verified container')

    def test_changed_selection_is_left_for_rebuilding(self):
        root,old,new,od,nd,key=self.fixture();p=new/'selection'/f'{key}.json';s=json.loads(p.read_bytes());s['chunks'][0]['sourceSHA256']='changed';write(p,s)
        result=self.run_import(old,new,od,nd);self.assertEqual(result.returncode,0,result.stderr)
        # Changed entries must not remain advertised in the imported catalogue.
        d=json.loads((new/'imported-sections.json').read_bytes());self.assertEqual(d['sections'],[]);self.assertEqual(d['changedSelectionsToRebuild'],[key])
        self.assertFalse((nd/(key+'-adaptive-0p5')).exists())
        catalog=json.loads((nd/'catalog.json').read_bytes());self.assertEqual(catalog['partitions'],[]);self.assertEqual(catalog['chunkCount'],0)

    def test_corrupt_container_is_refused(self):
        root,old,new,od,nd,key=self.fixture();(od/(key+'-adaptive-0p5')/'terrain.ratpack').write_bytes(b'corrupted')
        result=self.run_import(old,new,od,nd);self.assertNotEqual(result.returncode,0);self.assertIn('Container checksum',result.stderr);self.assertFalse((nd/'catalog.json').exists())


if __name__=='__main__':unittest.main()
