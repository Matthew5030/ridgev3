// Two-metre surface-error experiments: vary triangle size and old pack boundaries.
// The upstream MARTINI implementation remains unmodified (see vendor licence).
import fs from 'node:fs';
import path from 'node:path';
import Martini from './vendor/martini.mjs';
const out=process.argv[2],tolerance=2;
const read=i=>{let b=fs.readFileSync(path.join(out,`source-${i}.f32`));return new Float32Array(b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength));};
const originals=[read(0),read(1)];
function engine(terrain,size,rect,joined){
 const [x0,y0,x1,y1]=rect;
 const max=size-1,m=new Martini(size),tile=m.createTile(terrain),base=new Float32Array(terrain.length),diagonals=[];
 // Evaluate source points and native cell centres. A rejected triangle can stop
 // immediately: every profile in this experiment has the same 2 m tolerance.
 for(let i=0;i<m.numTriangles;i++){
  const k=i*4,ax=m.coords[k],ay=m.coords[k+1],bx=m.coords[k+2],by=m.coords[k+3];
  const mx=(ax+bx)>>1,my=(ay+by)>>1,cx=mx+my-ay,cy=my+ax-mx,j=my*size+mx;
  let za=terrain[ay*size+ax],zb=terrain[by*size+bx],zc=terrain[cy*size+cx];
  let den=(bx-ax)*(cy-ay)-(by-ay)*(cx-ax),err=0;
  const minX=Math.min(ax,bx,cx),maxX=Math.max(ax,bx,cx),minY=Math.min(ay,by,cy),maxY=Math.max(ay,by,cy);
  scan:for(let off of [0,.5])for(let y=minY+off;y<=maxY;y++)for(let x=minX+off;x<=maxX;x++){
   const u=((x-ax)*(cy-ay)-(y-ay)*(cx-ax))/den,v=((bx-ax)*(y-ay)-(by-ay)*(x-ax))/den;
   if(u<0||v<0||u+v>1)continue;
   let z=off===0?terrain[y*size+x]:(terrain[Math.floor(y)*size+Math.ceil(x)]+terrain[Math.ceil(y)*size+Math.floor(x)])/2;
   err=Math.max(err,Math.abs(za+u*(zb-za)+v*(zc-za)-z));
   if(err>tolerance){err=Infinity;break scan;}
  }
  base[j]=Math.max(base[j],err);
 }
 for(let y=0;y<max;y++)for(let x=0;x<max;x++){
  const a=y*size+x,err=Math.abs(terrain[a]+terrain[a+size+1]-terrain[a+1]-terrain[a+size])/2;
  if(err>tolerance)diagonals.push(a);
 }
 function propagate(errors){for(let i=m.numTriangles-1;i>=0;i--){
  const k=i*4,ax=m.coords[k],ay=m.coords[k+1],bx=m.coords[k+2],by=m.coords[k+3],mx=(ax+bx)>>1,my=(ay+by)>>1,cx=mx+my-ay,cy=my+ax-mx,j=my*size+mx;
  if(i<m.numParentTriangles)errors[j]=Math.max(errors[j],errors[((ay+cy)>>1)*size+((ax+cx)>>1)],errors[((by+cy)>>1)*size+((bx+cx)>>1)]);
 }}
 return cap=>{
  tile.errors.set(base);
  // Retain only the real area's outside boundary at native resolution. For the
  // joined case the old internal boundary has no special treatment; the mesh grid origin is shifted.
  for(let y=y0;y<=y1;y++)for(let x of [x0,x1])tile.errors[y*size+x]=Infinity;
  for(let x=x0;x<=x1;x++)for(let y of [y0,y1])tile.errors[y*size+x]=Infinity;
  for(let a of diagonals)for(let j of[a,a+1,a+size,a+size+1])tile.errors[j]=Infinity;
  if(cap!==null)for(let i=0;i<m.numTriangles;i++){
   const k=i*4,ax=m.coords[k],ay=m.coords[k+1],bx=m.coords[k+2],by=m.coords[k+3];
   if((ax-bx)**2+(ay-by)**2>2*cap*cap)tile.errors[((ay+by)>>1)*size+((ax+bx)>>1)]=Infinity;
  }
  propagate(tile.errors);
  let mesh=tile.getMesh(tolerance),v=mesh.vertices,t=mesh.triangles;
  const cells=new Map(),lookup=new Int32Array(size*size).fill(-1);
  for(let i=0;i<v.length/2;i++)lookup[v[2*i+1]*size+v[2*i]]=i;
  for(let i=0;i<t.length;i+=3){
   const a=t[i]*2,b=t[i+1]*2,c=t[i+2]*2,x=Math.min(v[a],v[b],v[c]),y=Math.min(v[a+1],v[b+1],v[c+1]);
   if(Math.max(v[a],v[b],v[c])-x!==1||Math.max(v[a+1],v[b+1],v[c+1])-y!==1)continue;
   const key=y*max+x;
   if(cells.has(key)){let j=cells.get(key),k=y*size+x;t.set([lookup[k],lookup[k+size],lookup[k+1]],j);t.set([lookup[k+1],lookup[k+size],lookup[k+size+1]],i);cells.delete(key);}else cells.set(key,i);
  }
  if(joined){
   // The joined rectangle has a shifted origin, so the old tile grid no longer
   // coincides with the RTIN subdivision grid. Discard all padding; Python checks
   // the real area is covered completely and only real source samples remain.
   let kept=[];
   for(let i=0;i<t.length;i+=3){
    let inside=[t[i],t[i+1],t[i+2]].every(k=>v[2*k]>=x0&&v[2*k]<=x1&&v[2*k+1]>=y0&&v[2*k+1]<=y1);
    if(inside)kept.push(t[i],t[i+1],t[i+2]);
   }
   const remap=new Int32Array(v.length/2).fill(-1),coords=[];
   for(let i=0;i<kept.length;i++){let old=kept[i];if(remap[old]<0){remap[old]=coords.length/2;coords.push(v[old*2]-x0,v[old*2+1]-y0);}kept[i]=remap[old];}
   mesh={vertices:new Uint16Array(coords),triangles:new Uint32Array(kept)};
  }
  return mesh;
 };
}
const start=performance.now();
const separate=originals.map(h=>engine(h,513,[0,0,512,512],false));
const square=new Float32Array(2049*2049);
for(let y=0;y<2049;y++){
 let realY=Math.max(0,Math.min(y-1,1024)),source=originals[realY<=512?0:1],row=realY<=512?realY:realY-512;
 for(let x=0;x<2049;x++)square[y*2049+x]=source[row*513+Math.max(0,Math.min(x-1,512))];
}
const joined=engine(square,2049,[1,1,513,1025],true),profiles=[];
for(let layout of ['tiles','joined'])for(let cap of [8,16,32,64,null]){
 let id=`layout-${layout}-${cap??'uncapped'}`,started=performance.now(),meshes=layout==='tiles'?separate.map(f=>f(cap)):[joined(cap)];
 const parts=meshes.map((mesh,i)=>{
  fs.writeFileSync(path.join(out,`${id}-${i}.xy`),Buffer.from(mesh.vertices.buffer));fs.writeFileSync(path.join(out,`${id}-${i}.tri`),Buffer.from(mesh.triangles.buffer));
  return{xy:`${id}-${i}.xy`,tri:`${id}-${i}.tri`,yOffset:layout==='tiles'?512*i:0,vertices:mesh.vertices.length/2,triangles:mesh.triangles.length/3};
 });
 profiles.push({id,layout,maxCellSteps:cap,toleranceMetres:tolerance,extractionMs:performance.now()-started,parts});
}
fs.writeFileSync(path.join(out,'layout-candidates.json'),JSON.stringify({preparationAndExtractionMs:performance.now()-start,profiles},null,2));
console.log(JSON.stringify(profiles.map(p=>({id:p.id,triangles:p.parts.reduce((n,m)=>n+m.triangles,0)}))));
