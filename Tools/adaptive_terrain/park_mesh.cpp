// Offline fixed-tolerance RTIN compiler. Topology adapted from MARTINI (ISC),
// copyright (c) 2019 Mapbox. See vendor/MARTINI-LICENSE.
// All candidate triangles are checked against native vertices and NE-SW cell
// centres. These include all intersections of RTIN and native surface edges.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <functional>
#include <iostream>
#include <sstream>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <vector>
using namespace std;
constexpr int S=513,M=512,N=S*S,NT=M*M*2-2,NP=NT-M*M;
struct Point {int x,y;};
struct Tri {Point a,b,c;};
int idx(Point p){return p.y*S+p.x;}
Point mid(Point a,Point b){return {(a.x+b.x)/2,(a.y+b.y)/2};}
vector<int16_t> heights(N);
// Work in source decimetres, avoiding float32 height quantisation during tests.
double source(double x,double y){int ix=floor(x),iy=floor(y);return x==ix?heights[iy*S+ix]:(heights[iy*S+ix+1]+heights[(iy+1)*S+ix])*0.5;}
double check(Tri t,double stop){
 auto [a,b,c]=t;double den=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x),e=0;
 int x0=min({a.x,b.x,c.x}),x1=max({a.x,b.x,c.x}),y0=min({a.y,b.y,c.y}),y1=max({a.y,b.y,c.y});
 for(double off:{0.,.5}) for(double y=y0+off;y<=y1;y++) for(double x=x0+off;x<=x1;x++){
  double u=((x-a.x)*(c.y-a.y)-(y-a.y)*(c.x-a.x))/den,v=((b.x-a.x)*(y-a.y)-(b.y-a.y)*(x-a.x))/den;
  if(u<0||v<0||u+v>1)continue;
  double z=heights[idx(a)]+u*(heights[idx(b)]-heights[idx(a)])+v*(heights[idx(c)]-heights[idx(a)]);
  e=max(e,abs(z-source(x,y)));if(e>stop)return e;
 }return e;
}
template<class T> void write(ostream& f,T v){f.write(reinterpret_cast<char*>(&v),sizeof(v));}
struct MeshResult {string data;uint32_t vertices,triangles,width;double error;};
MeshResult compileMesh(const int16_t* input,double metres,bool nativeEdges){
 if(!isfinite(metres)||metres<.1||metres>16)throw runtime_error("tolerance must be between 0.1 and 16 metres");
 memcpy(heights.data(),input,N*2);
 for(auto h:heights)if(h==-32768)throw runtime_error("NoData in source");
 const double tolerance=metres*10-.001; // Leave a rounding margin in source decimetres.
 static const vector<Tri> coords=[](){vector<Tri> result;result.reserve(NT);for(int i=0;i<NT;i++){
  int id=i+2;Point a{0,0},b{0,0},c{0,0};if(id&1){b={M,M};c={M,0};}else{a={M,M};c={0,M};}
  while((id>>=1)>1){Point p=mid(a,b);if(id&1){b=a;a=c;}else{a=b;b=c;}c=p;}
  result.push_back({a,b,c});}return result;}();
 vector<uint8_t> split(N,0);
 for(auto t:coords)if(check(t,tolerance)>tolerance)split[idx(mid(t.a,t.b))]=1;
 // Identical native perimeter vertices on every chunk: no T-junctions.
 if(nativeEdges)for(int p=0;p<S;p++)for(int j:{p,M*S+p,p*S,p*S+M})split[j]=1;
 for(int y=0;y<M;y++)for(int x=0;x<M;x++){
  int k=y*S+x;double e=abs(heights[k]+heights[k+S+1]-heights[k+1]-heights[k+S])*.5;
  if(e>tolerance)for(int j:{k,k+1,k+S,k+S+1})split[j]=1;
 }
 for(int i=NP-1;i>=0;i--){auto [a,b,c]=coords[i];split[idx(mid(a,b))]|=split[idx(mid(a,c))]|split[idx(mid(b,c))];}
 vector<Tri> triangles;
 function<void(Tri)> visit=[&](Tri t){auto [a,b,c]=t;Point p=mid(a,b);if(abs(a.x-c.x)+abs(a.y-c.y)>1&&split[idx(p)]){visit({c,a,p});visit({b,c,p});}else triangles.push_back(t);};
 visit({{0,0},{M,M},{M,0}});visit({{M,M},{0,0},{0,M}});
 vector<int> cells(M*M,-1);
 for(int i=0;i<(int)triangles.size();i++){
  auto [a,b,c]=triangles[i];int x=min({a.x,b.x,c.x}),y=min({a.y,b.y,c.y});
  if(max({a.x,b.x,c.x})-x!=1||max({a.y,b.y,c.y})-y!=1)continue;
  int& previous=cells[y*M+x];if(previous<0)previous=i;else{triangles[previous]={{x,y},{x,y+1},{x+1,y}};triangles[i]={{x+1,y},{x,y+1},{x+1,y+1}};previous=-1;}
 }
 // Validate the final surface, after diagonal restoration (not just error tree).
 double error=0;int64_t area2=0;vector<int> lookup(N,-1);vector<Point> vertices;vector<uint32_t> indices;
 for(auto t:triangles){
  error=max(error,check(t,numeric_limits<double>::infinity()));auto [a,b,c]=t;
  int signedArea=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x);if(signedArea>=0)throw runtime_error("winding");area2-=signedArea;
  for(auto p:{a,b,c}){int& k=lookup[idx(p)];if(k<0){k=vertices.size();vertices.push_back(p);}indices.push_back(k);}
 }
 if(error>metres*10+.0000001||area2!=2*M*M)throw runtime_error("surface validation failed");
 if(nativeEdges)for(int p=0;p<S;p++)for(int j:{p,M*S+p,p*S,p*S+M})if(lookup[j]<0)throw runtime_error("missing seam vertex");
 uint32_t width=vertices.size()<=65536?2:4;
 ostringstream out(ios::binary);out.write("RME1",4);write(out,uint32_t(vertices.size()));write(out,uint32_t(triangles.size()));write(out,width);write(out,uint32_t(S));write(out,float(.1));write(out,float(0));
 for(auto p:vertices){write(out,uint16_t(p.x));write(out,uint16_t(p.y));write(out,heights[idx(p)]);}
 for(auto k:indices){if(width==2)write(out,uint16_t(k));else write(out,k);}
 return {out.str(),uint32_t(vertices.size()),uint32_t(triangles.size()),width,error/10};
}
#ifdef RIDGE_MESH_LIBRARY
// Process-local scratch arrays: callers serialize invocations in each process.
extern "C" int ridge_compile_mesh(const int16_t* input,double tolerance,int nativeEdges,void* output,size_t capacity,size_t* written,double* error,char* message,size_t messageCapacity){
 try{auto result=compileMesh(input,tolerance,nativeEdges!=0);if(result.data.size()>capacity)throw runtime_error("mesh output capacity");memcpy(output,result.data.data(),result.data.size());*written=result.data.size();*error=result.error;return 0;}
 catch(const exception&e){if(messageCapacity){strncpy(message,e.what(),messageCapacity-1);message[messageCapacity-1]=0;}return 1;}
}
#else
int main(int argc,char**argv){try{
 if(argc<3||argc>5)throw runtime_error("usage: park_mesh source-int16 output.rmesh [tolerance-metres] [adaptive-edges]");
 if(argc==5&&string(argv[4])!="adaptive-edges")throw runtime_error("unknown edge mode");
 ifstream input(argv[1],ios::binary|ios::ate);if(!input||input.tellg()!=N*2)throw runtime_error("source byte count");input.seekg(0);vector<int16_t> data(N);input.read(reinterpret_cast<char*>(data.data()),N*2);
 auto result=compileMesh(data.data(),argc>=4?stod(argv[3]):.5,argc<5);
 ofstream out(argv[2],ios::binary);out.write(result.data.data(),result.data.size());out.close();if(!out)throw runtime_error("write failed");
 cout<<"{\"vertices\":"<<result.vertices<<",\"triangles\":"<<result.triangles<<",\"indexWidth\":"<<result.width<<",\"maxErrorMetres\":"<<result.error<<",\"metalGeometryBytes\":"<<result.vertices*48ULL+result.triangles*12ULL<<",\"compactBytes\":"<<result.data.size()<<"}\n";
}catch(const exception&e){cerr<<e.what()<<"\n";return 1;}}
#endif
