#!/usr/bin/env python3
"""Compare shared geographic pixels across independently built parent mosaics."""
import argparse,json,re
from pathlib import Path
import numpy as np
import rasterio
from rasterio.windows import Window


def check(folder,report):
    files={tuple(map(int,re.search(r'x(\d+)-y(\d+)',p.stem).groups())):p for p in folder.glob('world-z10-*.tif')}
    results=[]
    for (x,y),a in sorted(files.items()):
        for neighbour in [(x+1,y),(x,y+1)]:
            if neighbour not in files:continue
            b=files[neighbour]
            with rasterio.open(a) as left,rasterio.open(b) as right:
                res=left.res[0];assert abs(res-right.res[0])<1e-12
                bounds=[max(left.bounds.left,right.bounds.left)+24*res,max(left.bounds.bottom,right.bounds.bottom)+24*res,min(left.bounds.right,right.bounds.right)-24*res,min(left.bounds.top,right.bounds.top)-24*res]
                if bounds[0]>=bounds[2] or bounds[1]>=bounds[3]:raise ValueError('Insufficient shared mosaic halo')
                def read(ds):
                    col=round((bounds[0]-ds.bounds.left)/res);row=round((ds.bounds.top-bounds[3])/res)
                    width=round((bounds[2]-bounds[0])/res);height=round((bounds[3]-bounds[1])/res)
                    return ds.read(window=Window(col,row,width,height)).astype(np.int16)
                delta=np.abs(read(left)-read(right))
                result=dict(a=a.stem,b=b.stem,max=int(delta.max()),mean=float(delta.mean()),p99=float(np.percentile(delta,99)),samples=int(delta.size))
                results.append(result)
    # Independently encoded uint8 mosaics can differ by a few channel levels
    # after separate VRT warps and palette rounding. These limits catch visible
    # edge changes while tolerating low-amplitude quantization noise.
    summary=dict(edges=len(results),max=max((r['max'] for r in results),default=0),mean=max((r['mean'] for r in results),default=0),failures=[r for r in results if r['mean']>.25 or r['p99']>3 or r['max']>32],comparisons=results)
    report.write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps({k:v for k,v in summary.items() if k!='comparisons'},indent=2))
    if summary['failures']:raise ValueError('Geographic mosaic seams need review')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('folder',type=Path);p.add_argument('--report',type=Path,required=True);a=p.parse_args();check(a.folder,a.report)
