// Lossless topology codec for the canonical RTIN RME1 meshes emitted by park_mesh.
// The adaptive decisions and source heights are unchanged. Encode accepts only
// meshes that reconstruct byte-for-byte; it does not simplify terrain.
// RTIN traversal/diagonal restoration follows park_mesh.cpp (MARTINI, ISC).
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
using namespace std;
constexpr int S=513,M=512,N=S*S;
struct P{int x,y;};
struct T{P a,b,c;};
int at(P p){return p.y*S+p.x;}
P mid(P a,P b){return {(a.x+b.x)/2,(a.y+b.y)/2};}
vector<uint8_t> readFile(const string& path){ifstream f(path,ios::binary|ios::ate);if(!f)throw runtime_error("open input");auto size=f.tellg();if(size<28||size>16*1024*1024)throw runtime_error("input size");vector<uint8_t>b(size);f.seekg(0);f.read((char*)b.data(),b.size());if(!f)throw runtime_error("read input");return b;}
uint32_t u32(const vector<uint8_t>&b,size_t p){if(p+4>b.size())throw runtime_error("short header");return b[p]|uint32_t(b[p+1])<<8|uint32_t(b[p+2])<<16|uint32_t(b[p+3])<<24;}
uint16_t u16(const vector<uint8_t>&b,size_t p){if(p+2>b.size())throw runtime_error("short vertex");return b[p]|uint16_t(b[p+1])<<8;}
void put32(vector<uint8_t>&b,uint32_t n){for(int k=0;k<4;k++)b.push_back(n>>(k*8));}
void put16(vector<uint8_t>&b,uint16_t n){b.push_back(n);b.push_back(n>>8);}
struct Header{uint32_t nv,nt,iw;};
Header header(const vector<uint8_t>&b,const char*magic){if(memcmp(b.data(),magic,4)||u32(b,16)!=513)throw runtime_error("format/grid");Header h{u32(b,4),u32(b,8),u32(b,12)};if(h.nv>N||h.nv<4||h.nt<2||h.nt>2*M*M||h.iw!=(h.nv<=65536?2:4))throw runtime_error("mesh counts");return h;}
void restore(vector<T>&ts){vector<int>cells(M*M,-1);for(int i=0;i<(int)ts.size();i++){auto[a,b,c]=ts[i];int x=min({a.x,b.x,c.x}),y=min({a.y,b.y,c.y});if(max({a.x,b.x,c.x})-x!=1||max({a.y,b.y,c.y})-y!=1)continue;int&prev=cells[y*M+x];if(prev<0)prev=i;else{ts[prev]={{x,y},{x,y+1},{x+1,y}};ts[i]={{x+1,y},{x,y+1},{x+1,y+1}};prev=-1;}}}
vector<uint8_t> reconstruct(const vector<uint8_t>&b){auto h=header(b,"RAT1");if(b.size()<32)throw runtime_error("short topology header");uint32_t bits=u32(b,28);if(bits>2*M*M)throw runtime_error("topology limit");size_t size=(bits+7)/8;if(b.size()!=32+size+h.nv*2)throw runtime_error("topology payload size");uint32_t used=0;vector<T>ts;ts.reserve(h.nt);
 function<void(T)>visit=[&](T t){auto[a,c,d]=t; // Names are local; t.b is c here.
  if(abs(a.x-d.x)+abs(a.y-d.y)>1){if(used>=bits)throw runtime_error("truncated topology");bool split=(b[32+used/8]>>(used%8))&1;used++;if(split){P p=mid(a,c);visit({d,a,p});visit({c,d,p});return;}}
  if(ts.size()>=h.nt)throw runtime_error("too many triangles");ts.push_back(t);
 };visit({{0,0},{M,M},{M,0}});visit({{M,M},{0,0},{0,M}});if(used!=bits||ts.size()!=h.nt)throw runtime_error("topology counts");restore(ts);
 vector<P>vs;vector<int>lookup(N,-1);vector<uint32_t>indices;indices.reserve(h.nt*3);
 for(auto t:ts)for(auto p:{t.a,t.b,t.c}){int&k=lookup[at(p)];if(k<0){k=vs.size();vs.push_back(p);}indices.push_back(k);}
 if(vs.size()!=h.nv)throw runtime_error("vertex count");vector<uint8_t>out(b.begin(),b.begin()+28);memcpy(out.data(),"RME1",4);out.reserve(28+h.nv*6+h.nt*3*h.iw);
 for(size_t i=0;i<vs.size();i++){put16(out,vs[i].x);put16(out,vs[i].y);put16(out,u16(b,32+size+i*2));}
 for(auto k:indices){if(h.iw==2)put16(out,k);else put32(out,k);}return out;
}
vector<uint8_t> encode(const vector<uint8_t>&b){auto h=header(b,"RME1");if(b.size()!=28+h.nv*6+h.nt*3*h.iw)throw runtime_error("RME1 size");vector<uint8_t>present(N,0),heights,stream;heights.reserve(h.nv*2);
 for(uint32_t i=0;i<h.nv;i++){int x=u16(b,28+i*6),y=u16(b,30+i*6);if(x>M||y>M||present[y*S+x])throw runtime_error("source coordinate");present[y*S+x]=1;put16(heights,u16(b,32+i*6));}
 uint32_t bits=0;function<void(T)>visit=[&](T t){auto[a,c,d]=t;if(abs(a.x-d.x)+abs(a.y-d.y)<=1)return;P p=mid(a,c);bool split=present[at(p)];if(bits%8==0)stream.push_back(0);if(split)stream.back()|=1<<(bits%8);bits++;if(split){visit({d,a,p});visit({c,d,p});}};
 visit({{0,0},{M,M},{M,0}});visit({{M,M},{0,0},{0,M}});vector<uint8_t>out(b.begin(),b.begin()+28);memcpy(out.data(),"RAT1",4);put32(out,bits);out.insert(out.end(),stream.begin(),stream.end());out.insert(out.end(),heights.begin(),heights.end());
 if(reconstruct(out)!=b)throw runtime_error("mesh is not canonical: lossless round-trip failed");return out;
}
extern "C" int ridge_compact_transform(int mode,const uint8_t*input,size_t length,uint8_t*output,size_t capacity,size_t*written,char*error,size_t errorCapacity){
 try{if(length<28||length>16*1024*1024)throw runtime_error("input size");vector<uint8_t>b(input,input+length);auto result=mode==0?encode(b):reconstruct(b);if(result.size()>capacity)throw runtime_error("output capacity");memcpy(output,result.data(),result.size());*written=result.size();return 0;}
 catch(const exception&e){if(errorCapacity){strncpy(error,e.what(),errorCapacity-1);error[errorCapacity-1]=0;}return 1;}
}
int main(int argc,char**argv){try{if(argc!=4)throw runtime_error("usage: compact_mesh encode|decode input output");auto input=readFile(argv[2]);vector<uint8_t>output;string mode=argv[1];if(mode=="encode")output=encode(input);else if(mode=="decode")output=reconstruct(input);else throw runtime_error("mode");ofstream f(argv[3],ios::binary|ios::trunc);if(!f)throw runtime_error("open output");f.write((char*)output.data(),output.size());f.close();if(!f)throw runtime_error("write output");cout<<"{\"inputBytes\":"<<input.size()<<",\"outputBytes\":"<<output.size()<<"}\n";return 0;}catch(const exception&e){cerr<<e.what()<<"\n";return 1;}}
