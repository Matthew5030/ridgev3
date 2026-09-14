// Offline experiment. Uses unmodified upstream MARTINI topology/extraction (ISC).
// Custom error field checks the existing app's surface, including cell centres.
import fs from 'node:fs';
import path from 'node:path';
import Martini from './vendor/martini.mjs';
const out=process.argv[2],requested=process.argv[3]?JSON.parse(process.argv[3]):[.4999,1,2,3];
const start=performance.now(),martini=new Martini(513);
function propagate(errors){
 for(let i=martini.numTriangles-1;i>=0;i--){
  const k=i*4,ax=martini.coords[k],ay=martini.coords[k+1],bx=martini.coords[k+2],by=martini.coords[k+3];
  const mx=(ax+bx)>>1,my=(ay+by)>>1,cx=mx+my-ay,cy=my+ax-mx,j=my*513+mx;
  if(i<martini.numParentTriangles) errors[j]=Math.max(errors[j],errors[((ay+cy)>>1)*513+((ax+cx)>>1)],errors[((by+cy)>>1)*513+((bx+cx)>>1)]);
 }
}
const tiles=[0,1].map(i=>{
 const b=fs.readFileSync(path.join(out,`source-${i}.f32`));
 const terrain=new Float32Array(b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength));
 const tile=martini.createTile(terrain),base=new Float32Array(terrain.length),diagonals=[];
 for(let i=0;i<martini.numTriangles;i++){
  const k=i*4,ax=martini.coords[k],ay=martini.coords[k+1],bx=martini.coords[k+2],by=martini.coords[k+3];
  const mx=(ax+bx)>>1,my=(ay+by)>>1,cx=mx+my-ay,cy=my+ax-mx,j=my*513+mx;
  if((ax-bx)**2+(ay-by)**2>128){base[j]=Infinity;continue;}
  let za=terrain[ay*513+ax],zb=terrain[by*513+bx],zc=terrain[cy*513+cx];
  let den=(bx-ax)*(cy-ay)-(by-ay)*(cx-ax),err=0;
  let minX=Math.min(ax,bx,cx),maxX=Math.max(ax,bx,cx),minY=Math.min(ay,by,cy),maxY=Math.max(ay,by,cy);
  for(let off of [0,.5])for(let y=minY+off;y<=maxY;y++)for(let x=minX+off;x<=maxX;x++){
   let u=((x-ax)*(cy-ay)-(y-ay)*(cx-ax))/den,v=((bx-ax)*(y-ay)-(by-ay)*(x-ax))/den;
   if(u<0||v<0||u+v>1)continue;
   let z=off===0?terrain[y*513+x]:(terrain[Math.floor(y)*513+Math.ceil(x)]+terrain[Math.ceil(y)*513+Math.floor(x)])/2;
   err=Math.max(err,Math.abs(za+u*(zb-za)+v*(zc-za)-z));
  }
  base[j]=Math.max(base[j],err);
 }
 // Native edges are a deliberately conservative, deterministic seam policy.
 for(let p=0;p<513;p++)for(let j of[p,512*513+p,p*513,p*513+512])base[j]=Infinity;
 for(let y=0;y<512;y++)for(let x=0;x<512;x++){
  let a=y*513+x,err=Math.abs(terrain[a]+terrain[a+514]-terrain[a+1]-terrain[a+513])/2;
  if(err>0)diagonals.push([a,err]);
 }
 return{tile,base,diagonals};
});
const preparationMs=performance.now()-start;
function nativeDiagonal(m){
 const cell=new Map(),lookup=new Int32Array(513*513).fill(-1),v=m.vertices,t=m.triangles;
 for(let i=0;i<v.length/2;i++)lookup[v[2*i+1]*513+v[2*i]]=i;
 for(let i=0;i<t.length;i+=3){
  let a=t[i]*2,b=t[i+1]*2,c=t[i+2]*2,x=Math.min(v[a],v[b],v[c]),y=Math.min(v[a+1],v[b+1],v[c+1]);
  if(Math.max(v[a],v[b],v[c])-x!==1||Math.max(v[a+1],v[b+1],v[c+1])-y!==1)continue;
  let key=y*512+x;
  if(cell.has(key)){let j=cell.get(key),k=y*513+x;t.set([lookup[k],lookup[k+513],lookup[k+1]],j);t.set([lookup[k+1],lookup[k+513],lookup[k+514]],i);cell.delete(key);}else cell.set(key,i);
 }
 return m;
}
function meshes(error,fix=false){return tiles.map(({tile,base,diagonals})=>{
 tile.errors.set(base);
 // Fully triangulate native cells whose opposite diagonal alone exceeds the
 // requested surface tolerance, then restore the app's NE–SW diagonal.
 for(let [a,err]of diagonals)if(err>error)for(let j of[a,a+1,a+513,a+514])tile.errors[j]=Infinity;
 propagate(tile.errors);
 let m=tile.getMesh(error);return fix?nativeDiagonal(m):m;
});}
function count(ms){return ms.reduce((n,m)=>n+m.triangles.length/3,0);}
let profiles=requested.map(e=>({id:`error-${String(e).replaceAll('.','p')}`,threshold:e}));
let lo=0,hi=64;if(count(meshes(hi))>65536)throw Error('Seam/minimum-detail floor exceeds comparison budget');
for(let i=0;i<25;i++){let mid=(lo+hi)/2;if(count(meshes(mid))>65536)lo=mid;else hi=mid;}
profiles.push({id:'matched',threshold:hi});
for(let p of profiles){const start=performance.now(),ms=meshes(p.threshold,true);p.extractionMs=performance.now()-start;p.errorPreparationMs=preparationMs;p.tiles=ms.map((m,i)=>{fs.writeFileSync(path.join(out,`${p.id}-${i}.xy`),Buffer.from(m.vertices.buffer));fs.writeFileSync(path.join(out,`${p.id}-${i}.tri`),Buffer.from(m.triangles.buffer));return{vertices:m.vertices.length/2,triangles:m.triangles.length/3};});}
fs.writeFileSync(path.join(out,'mesh-candidates.json'),JSON.stringify(profiles,null,2));console.log(JSON.stringify(profiles));
