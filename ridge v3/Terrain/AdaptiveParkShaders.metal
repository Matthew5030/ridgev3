#include <metal_stdlib>
using namespace metal;
// Experiment: original packed 6-byte vertices stay packed on the GPU.
struct ParkUniforms { float4x4 vp; float4 rect; };
struct ParkOut { float4 position [[position]]; float3 world; };
vertex ParkOut parkVertex(uint id [[vertex_id]], device const packed_ushort3 *v [[buffer(0)]], constant ParkUniforms &u [[buffer(1)]]) {
 ushort3 p=v[id];
 float3 world=float3(u.rect.x+float(p.x)/512*u.rect.z, float(as_type<short>(p.z))*.0001, u.rect.y+float(p.y)/512*u.rect.w);
 return {u.vp*float4(world,1),world};
}
fragment float4 parkFragment(ParkOut in [[stage_in]]) {
 float3 n=normalize(cross(dfdx(in.world),dfdy(in.world)));if(n.y<0)n=-n;
 float light=.58+.42*max(0.,dot(n,normalize(float3(-.6,1.,.35))));
 float h=in.world.y*1000.;float3 base=mix(float3(.65,.76,.52),float3(.86,.83,.68),smoothstep(100.,950.,h));
 // A diagnostic relief colour, deliberately not presented as cartography.
 return float4(base*light,1);
}
