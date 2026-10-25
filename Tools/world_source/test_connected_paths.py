import unittest
from publish_connected_paths import connect,inside,walking_edges
class ConnectedPathsTests(unittest.TestCase):
    def test_boundary_identity_and_original_topology(self):
        def graph(parent,way,lat=53):
            return dict(nodes=[dict(id=0,longitude=0,latitude=lat,elevationMeters=20),dict(id=1,longitude=parent,latitude=lat,elevationMeters=20)],edges=[dict(from_=0,to=1,sourceFeatureID=f'osm:way:{way}:z10-x500-y333:clip-0000')])
        left=graph(-0.1,10);right=graph(0.1,10)
        for g in [left,right]:
            for e in g['edges']:e['from']=e.pop('from_')
        a=dict(minLongitude=-1,maxLongitude=0,minLatitude=52,maxLatitude=54)
        b=dict(minLongitude=0,maxLongitude=1,minLatitude=52,maxLatitude=54)
        _,li=connect(left,a,'left');_,ri=connect(right,b,'right')
        self.assertEqual(li[0],ri[0]);self.assertNotEqual(li[1],ri[1])
        right['edges'][0]['sourceFeatureID']='osm:way:99:z10-x501-y333:clip-0000'
        _,different=connect(right,b,'right');self.assertNotEqual(li[0],different[0])
        right['nodes'][0]['longitude']=0.00001
        _,nearby=connect(right,b,'right');self.assertNotEqual(li[0],nearby[0])
        self.assertTrue(inside(a,left['nodes'][0]));self.assertFalse(inside(a,right['nodes'][1]))
    def test_walking_road_evidence(self):
        def prepare(tags,bidirectional=True):
            g=dict(edges=[dict(id=1,sourceFeatureID='osm:way:1',pathType='majorRoad',access='unknown',bidirectional=bidirectional)])
            m=dict(features=[dict(id='osm:way:1',source=dict(tags=tags))])
            return walking_edges(g,m)
        for kind in ['primary','secondary','trunk']:
            self.assertEqual(prepare(dict(highway=kind))[0]['pathType'],kind)
        for kind in ['motorway','motorway_link']:
            self.assertEqual(prepare(dict(highway=kind,foot='yes')),[])
        for key in ['foot','access']:
            for value in ['private','no','customers','destination','delivery','forestry','agricultural','permit']:
                self.assertIn(prepare(dict(highway='residential',**{key:value}))[0]['access'],['private','no'])
        self.assertEqual(prepare(dict(highway='primary',access='private',foot='yes'))[0]['access'],'public')
        self.assertEqual(prepare(dict(highway='trunk',motorroad='yes')),[])
        self.assertEqual(prepare(dict(highway='primary',foot='use_sidepath'))[0]['access'],'no')
        self.assertFalse(prepare(dict(highway='footway'),False)[0]['bidirectional'])
        with self.assertRaises(ValueError):walking_edges(dict(edges=[dict(sourceFeatureID='missing')]),dict(features=[]))

if __name__=='__main__':unittest.main()
