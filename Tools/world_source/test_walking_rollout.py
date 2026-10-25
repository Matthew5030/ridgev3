import hashlib, json, tempfile, unittest, zlib, struct, zipfile
from pathlib import Path
from pack_sections import build, raw
from publish_connected_paths import connect
from rollout_walking_network import upgrade_graph, repack_routing, read_parent


class WalkingRolloutTests(unittest.TestCase):
    def test_streamed_archive_verifies_and_keeps_only_routing_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            archive=Path(temp)/'map.zip'
            graph=dict(edges=[dict(sourceFeatureID='way:1')])
            semantic=dict(features=[dict(id='way:1',source=dict(tags=dict(highway='primary')),geometry=dict(coordinates=[1,2])),
                                    dict(id='building:2',source=dict(tags=dict(building='yes')))])
            members={'routing/graph.json':raw(graph),'map-data.ridgemap':raw(semantic)}
            manifest=dict(files=[dict(path=name,sizeBytes=len(data),sha256=hashlib.sha256(data).hexdigest()) for name,data in members.items()])
            for compression in [zipfile.ZIP_STORED,zipfile.ZIP_DEFLATED]:
                with zipfile.ZipFile(archive,'w',compression=compression) as zipped:
                    zipped.writestr('manifest.json',raw(manifest))
                    zipped.writestr('unused-terrain.bin',b'irrelevant terrain'*10000)
                    for name,data in members.items():zipped.writestr(name,data)
                descriptor=dict(archiveSHA256=hashlib.sha256(archive.read_bytes()).hexdigest())
                result,evidence=read_parent(archive,descriptor)
                self.assertEqual(result,graph)
                self.assertEqual(evidence,dict(features=[dict(id='way:1',source=dict(tags=dict(highway='primary')))]))
                with self.assertRaises(ValueError):read_parent(archive,dict(archiveSHA256='0'*64))

    def test_live_topology_and_elevations_survive_semantic_upgrade(self):
        bounds=dict(minLongitude=0,maxLongitude=1,minLatitude=0,maxLatitude=1)
        graph=dict(nodes=[dict(id=i,latitude=.5,longitude=.2+i*.1,elevationMeters=1) for i in range(3)],
            edges=[dict(id=i,**{'from':i,'to':i+1},distanceMeters=100,pathType='majorRoad',access='unknown',bidirectional=True,sourceFeatureID=f'way:{i}') for i in range(2)])
        semantic=dict(features=[dict(id='way:0',source=dict(tags=dict(highway='primary'))),dict(id='way:1',source=dict(tags=dict(highway='motorway')))])
        _,ids=connect(graph,bounds,'parent')
        live=dict(nodes=[dict(id=ids[i],coordinate=dict(latitude=.5,longitude=.2+i*.1),elevation=700+i) for i in range(3)],
            edges=[dict(**{'from':ids[i],'to':ids[i+1]},kind='majorRoad',access='unknown',bidirectional=True,distance=100) for i in range(2)])
        upgraded,proof=upgrade_graph(live,graph,semantic,bounds,'parent')
        self.assertEqual([n['elevation'] for n in upgraded['nodes']],[700,701])
        self.assertEqual(upgraded['edges'],[dict(live['edges'][0],kind='primary')])
        self.assertEqual(proof['excluded'],1)
        live['edges'][0]['from']=999
        with self.assertRaises(ValueError):upgrade_graph(live,graph,semantic,bounds,'parent')

    def test_overlapping_paths_need_no_permission_guess(self):
        bounds=dict(minLongitude=0,maxLongitude=1,minLatitude=0,maxLatitude=1)
        graph=dict(nodes=[dict(id=i,latitude=.5,longitude=.2+i*.1,elevationMeters=1) for i in range(2)],
            edges=[dict(id=i,**{'from':0,'to':1},distanceMeters=4.06,pathType='footpath',access='public',bidirectional=True,sourceFeatureID=f'way:{i}') for i in range(2)])
        semantic=dict(features=[dict(id='way:0',source=dict(tags=dict(highway='footway',foot='yes'))),dict(id='way:1',source=dict(tags=dict(highway='path',foot='yes')))])
        _,ids=connect(graph,bounds,'parent')
        live=dict(nodes=[dict(id=ids[i],coordinate=dict(latitude=.5,longitude=.2+i*.1),elevation=10) for i in range(2)],
            edges=[dict(**{'from':ids[0],'to':ids[1]},kind='footpath',access='public',bidirectional=True,distance=4.06)])
        upgraded,_=upgrade_graph(live,graph,semantic,bounds,'parent')
        self.assertEqual(upgraded,live)
        semantic['features'][1]['source']['tags']['foot']='private'
        with self.assertRaises(ValueError):upgrade_graph(live,graph,semantic,bounds,'parent')

    def test_rebuilt_download_changes_only_routing_payload(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);folder=root/'sources/world-test';folder.mkdir(parents=True);output=root/'new';output.mkdir()
            assets=[]
            for name,data in [('overview-32m.json',b'{"heights":[1,2,3]}'),('paths.json',b'{"nodes":[],"edges":[]}'),('c00-r00.rat.zlib',bytes(range(256))*100),('c00-r00.map',b'actual vector bytes')]:
                (folder/name).write_bytes(data);assets.append(dict(file=name,byteCount=len(data),sha256=hashlib.sha256(data).hexdigest()))
            (folder/'world.json').write_bytes(raw(dict(id='world-test',overview=assets[0],graph=assets[1],tiles=[dict(mesh=assets[2],map=assets[3])])) )
            entry=dict(id='world-test',path='sources/world-test/world.json');old=build(root,entry)
            graph_data=b'{"nodes":[],"edges":["new routing"]}'
            graph=dict(file='paths-connected-v2.json',byteCount=len(graph_data),sha256=hashlib.sha256(graph_data).hexdigest())
            new=repack_routing(folder/old['file'],old,'world-test',assets[1],graph,graph_data,output)
            payload=(output/new['file']).read_bytes();self.assertEqual(hashlib.sha256(payload).hexdigest(),new['sha256'])
            def chunks(data):
                size=struct.unpack('<I',data[8:12])[0];index=json.loads(data[12:12+size]);body=data[12+size:]
                return {e['sha256']:(body[e['offset']:e['offset']+e['storedByteCount']],e) for e in index['entries']}
            before=chunks((folder/old['file']).read_bytes());after=chunks(payload)
            for original in [assets[0],assets[2],assets[3]]:
                key=original['sha256'];self.assertEqual(before[key][0],after[key][0])
            data,e=after[graph['sha256']];self.assertEqual(zlib.decompress(data) if e['compressed'] else data,graph_data)
            wrong=dict(old,sha256='0'*64)
            with self.assertRaises(ValueError):repack_routing(folder/old['file'],wrong,'world-test',assets[1],graph,graph_data,output)
            self.assertFalse((output/'.routing-pack.tmp').exists())


if __name__=='__main__':unittest.main()
