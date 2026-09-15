"""Procedural landscape materials. No icons, generated imagery or new geometry.

Land-cover placement is sourced; internal material grain is synthetic appearance,
not surveyed rocks, plants, cracks or a change to walking difficulty.
"""
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from preview import category, mask_geometry
import prepare_packs as shared

CONFIG={
    'version':'ridge-material-preview-2',
    'palette':{'unknown':['#92977d','#aaa993'],'grassland':['#87916b','#a0a486'],
      'heath':['#6b6950','#9e8a67'],'scrub':['#596c3f','#899462'],
      'woodland':['#355440','#68805a'],'bare_rock':['#858b86','#aaada1'],
      'scree':['#8d9186','#adae9f'],'sand':['#baa676','#d9c99d'],
      'shingle':['#7e827b','#bab8a7'],'wetland':['#567965','#92a585'],
      'water':['#3f849a','#679eaa'],'building':['#877d70','#a59d8e']},
    'transitionHalfWidthMetres':12.0,
    'notes':'World-coordinate procedural colour/grain, normalized land-cover material weights with a 24 m visual transition band, LiDAR-derived local relief shading. Fine grain is synthetic material, not observed terrain. No discrete symbols or displacement.'
}
def color(hex):return np.array([int(hex[i:i+2],16) for i in (1,3,5)],dtype='float32')
def mix(a,b,t):return a+(b-a)*t[...,None]
def smooth(t):return t*t*(3-2*t)
def hash2(x,y,seed):
    # Arithmetic integer hash, fixed independently of Python process hash seed.
    v=(x.astype('int64')*374761393+y.astype('int64')*668265263+seed*1442695041).astype('uint64')
    v=(v^(v>>13))*np.uint64(1274126177);v^=v>>16
    return (v&np.uint64(0xffffff)).astype('float32')/16777215

def noise(x,y,scale,seed):
    u=x/scale;v=y/scale;ix=np.floor(u).astype('int64');iy=np.floor(v).astype('int64');fx=smooth((u-ix).astype('float32'));fy=smooth((v-iy).astype('float32'))
    a=hash2(ix,iy,seed);b=hash2(ix+1,iy,seed);c=hash2(ix,iy+1,seed);d=hash2(ix+1,iy+1,seed)
    return (a+(b-a)*fx)*(1-fy)+(c+(d-c)*fx)*fy

def soft_weight(mask, metres_per_pixel, variation):
    """Visual blend only; original semantic geometry is never mutated.

    Full material weight 12 m inside, zero 12 m outside, with a small
    deterministic transition variation; neighbouring weights normalize later.
    """
    from scipy.ndimage import distance_transform_edt
    inside=np.asarray(mask)>127
    if not inside.any():return np.zeros(inside.shape,dtype='float32')
    if inside.all():return np.ones(inside.shape,dtype='float32')
    signed=(distance_transform_edt(inside)-distance_transform_edt(~inside))*metres_per_pixel
    t=np.clip(.5+signed/(2*CONFIG['transitionHalfWidthMetres'])+(variation-.5)*.10,0,1)
    return smooth(t).astype('float32')

def render(features,heights,b,side=2368,contours=False):
    # Fixed equirectangular projection at 54°N: continuous across UK tiles,
    # close to metres here; no per-tile min/max or random seeds.
    x=np.linspace(b['minLongitude'],b['maxLongitude'],side,dtype='float64')[None,:]*111320*math.cos(math.radians(54))
    y=np.linspace(b['maxLatitude'],b['minLatitude'],side,dtype='float64')[:,None]*111320
    broad=noise(x,y,70,11);middle=noise(x,y,14,23);fine=noise(x,y,2.2,37);grain=noise(x,y,.7,41)
    field=np.clip(.40*broad+.30*middle+.20*fine+.10*grain,0,1)
    elevation=np.asarray(Image.fromarray(heights.astype('float32')*.1).resize((side,side),Image.Resampling.BILINEAR))
    valid=np.asarray(Image.fromarray((heights!=shared.NO_DATA).astype('uint8')*255).resize((side,side),Image.Resampling.NEAREST))>0
    base=mix(color(CONFIG['palette']['unknown'][0]),color(CONFIG['palette']['unknown'][1]),np.clip((elevation-200)/1000,0,1))
    base*= (.97+.06*field)[...,None]
    accumulated=np.zeros_like(base);total=np.zeros((side,side),dtype='float32');hard=[]
    for kind,colors in CONFIG['palette'].items():
        if kind=='unknown':continue
        mask=Image.new('L',(side,side))
        for f in features:
            if category(f)!=kind:continue
            fm=Image.new('L',(side,side));mask_geometry(fm,f['geometry'],b,side);mask=Image.fromarray(np.maximum(np.asarray(mask),np.asarray(fm)))
        if not mask.getbbox():continue
        metres_per_pixel=(b['maxLatitude']-b['minLatitude'])*111320/(side-1)
        alpha=np.asarray(mask,dtype='float32')/255 if kind in ('water','building') else soft_weight(mask,metres_per_pixel,middle)
        t=field
        if kind=='bare_rock':
            # Restrained mineral variation; remove the repeated vein pattern.
            t=np.clip(.58*broad+.27*middle+.10*fine+.05*grain,0,1)
            material=mix(color(colors[0]),color(colors[1]),t)
            material*= (.985+.03*grain)[...,None]
        elif kind in ('scree','shingle'):
            pebbles=noise(x+y*.24,y-x*.18,1.6,73)
            t=np.clip(.52*broad+.29*middle+.14*pebbles+.05*grain,0,1)
            material=mix(color(colors[0]),color(colors[1]),t)
            material*= (.97+.06*pebbles)[...,None]
        elif kind=='water':material=mix(color(colors[0]),color(colors[1]),broad*.6)
        else:
            t=np.clip(.58*broad+.30*middle+.09*fine+.03*grain,0,1)
            material=mix(color(colors[0]),color(colors[1]),t)
            material*= (.98+.04*fine)[...,None]
        if kind in ('water','building'):
            hard.append((material,alpha))
        else:
            accumulated+=material*alpha[...,None];total+=alpha
    # Adjacent surfaces blend into each other, not through an unrelated base
    # colour. Exposed unknown retains its neutral, explicitly unknown material.
    fallback=np.maximum(0,1-total)
    base=(accumulated+base*fallback[...,None])/np.maximum(1,total)[...,None]
    for material,alpha in hard:base=base*(1-alpha[...,None])+material*alpha[...,None]
    # Cavity shading comes from measured height differences, not noise geometry.
    # Noise adds only subdued grain lighting baked into the material.
    space=shared.spacing_meters(b,heights.shape[1],heights.shape[0]);h=heights.astype('float32')*.1
    from scipy.ndimage import gaussian_filter
    good=heights!=shared.NO_DATA
    safe=np.where(good,h,0)
    weights=gaussian_filter(good.astype('float32'),3)
    nearby=gaussian_filter(safe,3)/np.maximum(weights,1e-6)
    cavity=np.clip((nearby-h)/18,0,.45);cavity[~good]=0
    cavity=np.asarray(Image.fromarray(cavity.astype('float32')).resize((side,side),Image.Resampling.BILINEAR))
    gy,gx=np.gradient(np.where(good,h,nearby),space['northSouth'],space['eastWest'])
    relief=np.clip((-gx+gy)/np.sqrt(1+gx*gx+gy*gy),-.8,.8);relief[~good]=0
    relief=np.asarray(Image.fromarray(relief.astype('float32')).resize((side,side),Image.Resampling.BILINEAR))
    base*=(1-cavity*.12+relief*.09)[...,None]
    base[~valid]=color('#a6a292')
    image=Image.fromarray(np.clip(base,0,255).astype('uint8'))
    # Navigation ink: contours are optional, subordinate to material shading.
    if contours:
        overlay=image.copy();d=ImageDraw.Draw(overlay)
        for level,segments in shared.contour_segments(heights):
            for points in segments:d.line([(xx*(side-1)/(heights.shape[1]-1),yy*(side-1)/(heights.shape[0]-1)) for xx,yy in points],fill='#e5ddbb' if level%50==0 else '#cbbf9c',width=3 if level%50==0 else 1)
        image=Image.blend(image,overlay,.30)
    # Paths retain their source location; do not invent a physical dirt trail.
    d=ImageDraw.Draw(image)
    paints={'majorRoad':('#c3b297',8),'minorRoad':('#bdb9a3',6),'track':('#e2d5b8',3),'footpath':('#e0a7a2',3),'bridleway':('#d0b3d1',3),'unknownPath':('#cdc9b8',2),'water':('#65a6b7',3)}
    def line(g,k):
        if g['type']=='MultiLineString':
            for part in g['coordinates']:line({'type':'LineString','coordinates':part},k)
        if g['type']!='LineString':return
        points=[shared.pixels(b,p,side) for p in g['coordinates']];c,w=paints[k]
        if k in ('track','footpath','bridleway','unknownPath'):shared.dashed(d,points,c,w,dash=16,gap=11)
        else:d.line(points,fill=c,width=w,joint='curve')
    for k in paints:
        for f in features:
            if f['kind']==k:line(f['geometry'],k)
    return image
