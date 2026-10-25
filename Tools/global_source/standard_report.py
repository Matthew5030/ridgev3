"""Report actual published land coverage, separating LiDAR, standard and missing."""
import argparse,collections,copy,hashlib,json,math,sys
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import Patch
from shapely.geometry import box
from shapely.ops import unary_union
TOOLS=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(TOOLS/'world_source'))
sys.path.insert(0,str(TOOLS/'region_zones'))
from report_english_repair import geometry,draw
from preview_large_areas import analyse
from audit_coverage import km2


def classify(layout,catalog):
    layout=copy.deepcopy(layout)
    for region in layout['regions']:region.setdefault('kind','park' if region.get('parkID') else 'area')
    analyse(layout,catalog);sources={s['id']:s for s in catalog['sources']};result=[]
    for region in layout['regions']:
        land=geometry(region['mapShapes']);missing=geometry(region['missingShapes']);standard=[]
        for cell in region['cells']:
            for b in sources.get(cell['id'],{}).get('standardTerrain',[]):
                standard.append(box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude']))
        standard=unary_union(standard).intersection(land).difference(missing)
        lidar=land.difference(missing).difference(standard)
        assert abs(land.area-missing.area-standard.area-lidar.area)<1e-8
        result.append((region,land,lidar,standard,missing))
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);p.add_argument('--world',type=Path,required=True);a=p.parse_args()
    layout=json.loads((TOOLS.parents[0]/'ridge v3/Resources/uk-download-zones.json').read_bytes())
    before=json.loads((a.root/'catalog.before.json').read_bytes());raw=(a.world/'catalog.json').read_bytes();after=json.loads(raw)
    snapshots=[classify(layout,c) for c in [before,after]];rows=[]
    for old,new in zip(*snapshots):
        r,land,lidar,standard,missing=new
        if land.is_empty:continue
        rows.append(dict(id=r['id'],name=r['name'],landKm2=km2(land),lidarKm2=km2(lidar),standardKm2=km2(standard),missingKm2=km2(missing),previousMissingKm2=km2(old[4]),availability=r['stats']['availability']))
    report=dict(catalogSHA256=hashlib.sha256(raw).hexdigest(),beforeTiles=sum(s['tileCount'] for s in before['sources']),afterTiles=sum(s['tileCount'] for s in after['sources']),standardTiles=sum(s.get('standardTileCount',0) for s in after['sources']),regions=rows,availability=dict(collections.Counter(r['availability'] for r in rows)),totals={k:sum(r[k] for r in rows) for k in ['landKm2','lidarKm2','standardKm2','missingKm2','previousMissingKm2']},method='Actual catalog masks clipped to reviewed zone land polygons; approximate km². Standard denotes 30 m DSM source, not LiDAR.')
    output=a.root/'reports';output.mkdir(exist_ok=True);(output/'coverage.json').write_text(json.dumps(report,indent=2)+'\n')
    colours=['#8db18a','#77a8ce','#d58282'];fig,axes=plt.subplots(1,2,figsize=(11,11),layout='constrained')
    for ax,items,title in zip(axes,snapshots,['Before fallback','Published coverage']):
        for _,land,lidar,standard,missing in items:
            for g,c in zip([lidar,standard,missing],colours):
                if not g.is_empty:draw(ax,g,c)
        ax.set(xlim=(-9,2.1),ylim=(49.5,61),title=title);ax.set_aspect(1/math.cos(math.radians(55)));ax.set_facecolor('#edf1f2');ax.set_xticks([]);ax.set_yticks([])
    fig.legend(handles=[Patch(color=c,label=t) for c,t in zip(colours,['LiDAR','Standard terrain · 30 m source','Missing terrain'])],loc='outside lower center',ncol=3,frameon=False)
    fig.savefig(output/'coverage.png',dpi=160);plt.close(fig)
    print(json.dumps({k:v for k,v in report.items() if k!='regions'},indent=2))

if __name__=='__main__':main()
