import hashlib,http.server,importlib.util,json,tempfile,threading,unittest,urllib.request,urllib.error
from pathlib import Path
spec=importlib.util.spec_from_file_location('native_server',Path(__file__).with_name('native_server.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
audit_spec=importlib.util.spec_from_file_location('audit_origin',Path(__file__).with_name('audit_origin.py'))
audit_module=importlib.util.module_from_spec(audit_spec);audit_spec.loader.exec_module(audit_module)

class OriginTests(unittest.TestCase):
    def test_region_audit_includes_edge_download_members(self):
        zones=dict(regions=[dict(id='park-test',cells=[dict(id='world-centre')],
                               downloadCells=[dict(id='world-centre'),dict(id='world-edge')])])
        self.assertEqual(audit_module.region_source_ids(zones,'park-test'),{'world-centre','world-edge'})
    def test_contract(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);world=root/'dataset';world.mkdir();(world/'catalog.json').write_bytes(b'{"sources":[]}')
            source=world/'sources/world-test';source.mkdir(parents=True)
            external=root/'cache';external.mkdir();payload=bytes(range(256))*10
            name='section-'+64*'a'+'.ridgepack';(external/name).write_bytes(payload)
            (source/name).symlink_to(external/name);(source/'world.json').write_bytes(b'{}')
            (source/'paths-connected-v2.json').write_bytes(b'{"nodes":[],"edges":[]}')
            server=http.server.ThreadingHTTPServer(('127.0.0.1',0),module.Handler)
            server.root=root;server.world_name='dataset';server.daemon_threads=True
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            base='http://127.0.0.1:%d'%server.server_port
            def get(path,headers=None,method='GET'):
                return urllib.request.urlopen(urllib.request.Request(base+path,headers=headers or {},method=method),timeout=3)
            try:
                with get('/world/catalog.json') as response:
                    self.assertEqual(response.read(),b'{"sources":[]}');self.assertEqual(response.headers['Cache-Control'],'no-cache')
                with get('/world/sources/world-test/paths-connected-v2.json') as response:
                    self.assertEqual(response.read(),b'{"nodes":[],"edges":[]}')
                    self.assertIn('immutable',response.headers['Cache-Control'])
                url='/world/sources/world-test/'+name
                with get(url) as response:
                    self.assertEqual(response.read(),payload);self.assertIn('immutable',response.headers['Cache-Control'])
                for value,expected in [('bytes=7-19',payload[7:20]),('bytes=-12',payload[-12:]),('bytes=2550-',payload[2550:])]:
                    with get(url,{'Range':value}) as response:
                        self.assertEqual(response.status,206);self.assertEqual(response.read(),expected)
                with get(url,method='HEAD') as response:
                    self.assertEqual(int(response.headers['Content-Length']),len(payload));self.assertEqual(response.read(),b'')
                for path,status in [(url+'x',404),('/world/sources/world-test/standard-complete.json',404),('/world/../catalog.json',404),('/world/%2e%2e/catalog.json',404),('/north-york-moors-adaptive-0p5/pack.json',410)]:
                    with self.assertRaises(urllib.error.HTTPError) as error:get(path)
                    self.assertEqual(error.exception.code,status)
                with self.assertRaises(urllib.error.HTTPError) as error:get(url,{'Range':'bytes=99999-'})
                self.assertEqual(error.exception.code,416)
                # A publication-wide check must catch older broken pack links,
                # even when the catalog and sampled new sections are healthy.
                (world/'catalog.json').write_text(json.dumps(dict(sources=[dict(id='world-test',path='sources/world-test/world.json',pack=dict(file=name,byteCount=len(payload),sha256=hashlib.sha256(payload).hexdigest()))])))
                self.assertTrue(audit_module.audit(base+'/world/')['passed'])
                self.assertTrue(audit_module.audit(base+'/world/',source_ids={'world-test'},verify_content=True)['passed'])
                (external/name).unlink()
                result=audit_module.audit(base+'/world/')
                self.assertFalse(result['passed']);self.assertEqual(result['checked'],1)
                self.assertEqual(result['errors'][0]['error'],'HTTP 404')
            finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':unittest.main()
