"""Matte illustrated terrain: evidence-based colour, zero synthetic grain."""
import numpy as np
from PIL import Image,ImageDraw
from preview import category,mask_geometry
from materials import soft_weight,color
import prepare_packs as shared

CONFIG={
 'version':'ridge-illustrated-preview-1',
 'palette':{'grassland':'#a8bea0','heath':'#b9b39f','scrub':'#99b39d',
 'woodland':'#7d9f8c','bare_rock':'#c8c4b7','scree':'#c5c5b5','sand':'#d9c9a5',
 'shingle':'#c7c4b3','wetland':'#9dbbb0','water':'#71b3c4','building':'#b3a18c'},
 'notes':'Smooth matte illustrated palette, no noise, icons or baked relief. Subtle mapped land-cover tints with normalized 24 m transitions. Dynamic stylized lighting is applied by the Metal test renderer. Geometry and source lines unchanged.'
}

def render(features,heights,b,side=2368,contours=False):
    good=heights!=shared.NO_DATA
    h=np.asarray(Image.fromarray(np.where(good,heights*.1,350).astype('float32')).resize((side,side),Image.Resampling.BILINEAR))
    # Height is a quiet background tint, not a habitat classification.
    t=np.clip((h-250)/1000,0,1)[...,None]
    base=color('#b6bea4')+(color('#d2cbbc')-color('#b6bea4'))*t
    accum=np.zeros_like(base);total=np.zeros((side,side),dtype='float32');hard=[]
    metres=(b['maxLatitude']-b['minLatitude'])*111320/(side-1)
    for kind,paint in CONFIG['palette'].items():
        mask=Image.new('L',(side,side))
        for f in features:
            if category(f)!=kind:continue
            m=Image.new('L',(side,side));mask_geometry(m,f['geometry'],b,side);mask=Image.fromarray(np.maximum(np.asarray(mask),np.asarray(m)))
        if not mask.getbbox():continue
        if kind in ('water','building'):
            hard.append((color(paint),np.asarray(mask,dtype='float32')/255));continue
        alpha=soft_weight(mask,metres,.5)
        # Blend each cover into the common terrain palette for visual cohesion.
        surface=base*.20+color(paint)*.80
        accum+=surface*alpha[...,None];total+=alpha
    base=(accum+base*np.maximum(0,1-total)[...,None])/np.maximum(total,1)[...,None]
    for paint,alpha in hard:base=base*(1-alpha[...,None])+paint*alpha[...,None]
    image=Image.fromarray(np.clip(base,0,255).astype('uint8'))
    if contours:
        overlay=image.copy();d=ImageDraw.Draw(overlay)
        for level,segments in shared.contour_segments(heights):
            for points in segments:d.line([(x*(side-1)/(heights.shape[1]-1),y*(side-1)/(heights.shape[0]-1)) for x,y in points],fill='#847f6c',width=3 if level%50==0 else 1)
        image=Image.blend(image,overlay,.26)
    d=ImageDraw.Draw(image)
    paints={'majorRoad':('#cfb48c',9),'minorRoad':('#dfcdb0',6),'track':('#98846c',3),
            'footpath':('#b56e6b',3),'bridleway':('#94839e',3),'unknownPath':('#928d81',2),'water':('#70aabd',3)}
    def line(g,k):
        if g['type']=='MultiLineString':
            for p in g['coordinates']:line({'type':'LineString','coordinates':p},k)
        elif g['type']=='LineString':
            points=[shared.pixels(b,p,side) for p in g['coordinates']];ink,width=paints[k]
            if k in ('footpath','bridleway','track','unknownPath'):shared.dashed(d,points,ink,width,dash=18,gap=11)
            else:
                if k.endswith('Road'):d.line(points,fill='#f4ead7',width=width+4,joint='curve')
                d.line(points,fill=ink,width=width,joint='curve')
    for k in paints:
        for f in features:
            if f['kind']==k:line(f['geometry'],k)
    return image
