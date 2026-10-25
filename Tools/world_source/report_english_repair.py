#!/usr/bin/env python3
"""Compare real published tile masks; produce a land-clipped coverage map."""
import argparse,collections,copy,json,math,sys
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.path import Path as PlotPath
from matplotlib.patches import PathPatch,Patch
from shapely.geometry import Polygon,box
from shapely.geometry.polygon import orient
from shapely.ops import unary_union
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'region_zones'))
from preview_large_areas import analyse
from audit_coverage import km2


def geometry(shapes):return unary_union([Polygon(s['rings'][0],s['rings'][1:]) for s in shapes])


def draw(ax,geometry,colour):
    polys=[geometry] if geometry.geom_type=='Polygon' else [g for g in getattr(geometry,'geoms',[]) if g.geom_type=='Polygon']
    for polygon in polys:
        polygon=orient(polygon,sign=1);vertices=[];codes=[]
        for ring in [polygon.exterior,*polygon.interiors]:
            coords=np.asarray(ring.coords);vertices.extend(coords);codes.extend([PlotPath.MOVETO]+[PlotPath.LINETO]*(len(coords)-2)+[PlotPath.CLOSEPOLY])
        ax.add_patch(PathPatch(PlotPath(vertices,codes),facecolor=colour,edgecolor='none'))


def main():
    p=argparse.ArgumentParser();p.add_argument('--cache',type=Path,required=True);p.add_argument('--world',type=Path,required=True);a=p.parse_args()
    base=json.loads((HERE.parents[1]/'Artifacts/larger-regions-preview/regions.json').read_bytes())
    before=json.loads((a.cache/'world-stage/catalog.before.json').read_bytes());after=json.loads((a.world/'catalog.json').read_bytes())
    layouts=[]
    for catalog in [before,after]:
        layout=copy.deepcopy(base);analyse(layout,catalog);layouts.append(layout)
    changes=[]
    for old,new in zip(layouts[0]['regions'],layouts[1]['regions']):
        assert old['id']==new['id'];land=geometry(new['mapShapes']);area=km2(land)
        missing_before=km2(geometry(old['missingShapes']));missing_after=km2(geometry(new['missingShapes']))
        if missing_before-missing_after>.001:
            changes.append(dict(id=new['id'],name=new['name'],beforeDetailedLandPercent=100*(1-missing_before/area),afterDetailedLandPercent=100*(1-missing_after/area),recoveredLandKm2=missing_before-missing_after))
    report=dict(beforeAvailability=dict(collections.Counter(g['stats']['availability'] for g in layouts[0]['regions'])),afterAvailability=dict(collections.Counter(g['stats']['availability'] for g in layouts[1]['regions'])),recoveredLandKm2=sum(x['recoveredLandKm2'] for x in changes),changedRegions=changes,beforeTiles=sum(s['tileCount'] for s in before['sources']),afterTiles=sum(s['tileCount'] for s in after['sources']),scope='Land-clipped coverage derived from actual catalogue tile masks; km² are approximate regional polygon areas.')
    output=a.cache/'reports';output.mkdir(exist_ok=True);(output/'coverage-comparison.json').write_text(json.dumps(report,indent=2)+'\n')
    extent=box(-4.1,51.0,-1.9,53.7);fig,axes=plt.subplots(1,2,figsize=(10,11),layout='constrained')
    red='#d48080';green='#a4c6a5'
    for ax,layout,title in zip(axes,layouts,['Before recovery','After verified recovery']):
        land=unary_union([geometry(g['mapShapes']) for g in layout['regions']]).intersection(extent)
        missing=unary_union([geometry(g['missingShapes']) for g in layout['regions']]).intersection(extent)
        draw(ax,land,green);draw(ax,missing,red)
        for name,lon,lat in [('Ludlow sample',-2.718,52.368),('Leominster sample',-2.739,52.226)]:
            ax.plot(lon,lat,'.',color='#183e43',ms=5);ax.annotate(name,(lon,lat),xytext=(5,4),textcoords='offset points',fontsize=8,color='#183e43')
        ax.set(xlim=(-4.1,-1.9),ylim=(51,53.7),title=title,xlabel='Longitude',ylabel='Latitude');ax.set_aspect(1/math.cos(math.radians(52.4)));ax.set_facecolor('#eef1f2');ax.grid(alpha=.12)
    fig.legend(handles=[Patch(color=green,label='Prepared detailed terrain'),Patch(color=red,label='Missing detailed terrain')],loc='outside lower center',ncol=2,frameon=False)
    fig.savefig(output/'coverage-before-after.png',dpi=170);plt.close(fig)
    print(json.dumps(report,indent=2))


if __name__=='__main__':main()
