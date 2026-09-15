import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import simd

struct VaryingUniforms { var matrix: simd_float4x4; var crop: SIMD4<Float>; var mode: SIMD4<Float> }
struct Level: Decodable { var file: String; var width: Int; var height: Int; var sha256: String; var byteCount: Int }
struct Source: Decodable { var variants: [String:[Level]]; var widthMetres: Float; var depthMetres: Float; var maxHeight: Float; var vertexCount: Int; var indexCount: Int; var verticesSHA256: String; var indicesSHA256: String }
enum Failure: Error { case invalid(String) }
func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure.invalid(message) } }
func digest(_ d: Data) -> String { SHA256.hash(data:d).map { String(format:"%02x",$0) }.joined() }
let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let illustratedLightingAll=CommandLine.arguments.contains("--illustrated-lighting-all")
let illustratedLighting=CommandLine.arguments.contains("--illustrated-lighting") || illustratedLightingAll
let materialLightingAll=CommandLine.arguments.contains("--material-lighting-all")
let materialLighting=CommandLine.arguments.contains("--material-lighting") || materialLightingAll
let source=try JSONDecoder().decode(Source.self,from:Data(contentsOf:root.appendingPathComponent("source.json")))
guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw Failure.invalid("No Metal GPU") }
let shader="""
#include <metal_stdlib>
using namespace metal;
struct V { float3 p; float3 n; float2 uv; };
struct U { float4x4 matrix; float4 crop; float4 mode; };
struct O { float4 p [[position]]; float3 n; float2 uv; };
vertex O terrain(uint id [[vertex_id]], const device V* vertices [[buffer(0)]], constant U& u [[buffer(1)]]) {
  V v=vertices[id]; O o; o.p=u.matrix*float4(v.p,1);o.n=v.n;o.uv=v.uv;return o;
}
vertex O flat(uint id [[vertex_id]],constant U& u [[buffer(1)]]) {
  float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
  O o;o.p=float4(p[id],0,1);o.n=float3(0,1,0);o.uv=float2((p[id].x+1)*.5,(1-p[id].y)*.5)*u.crop.zw+u.crop.xy;return o;
}
fragment float4 ink(O in [[stage_in]],texture2d<float> map [[texture(0)]],sampler s [[sampler(0)]],constant U& u [[buffer(1)]]) {
  float3 c=map.sample(s,in.uv).rgb;
  if(u.mode.x>0) { float sunlight=max(0.0,dot(normalize(in.n),normalize(float3(-.45,.85,-.4))));
    if(u.mode.y>1.5) {
      float light=.55+.22*smoothstep(.12,.50,sunlight)+.24*smoothstep(.58,.95,sunlight);
      float3 tint=mix(float3(.83,.89,1.035),float3(1.055,1.025,.955),smoothstep(.12,.90,sunlight));
      c*=light*tint;
    }
    else if(u.mode.y>0) { c*=float3(.76,.86,1.0)*.34+float3(1.07,1.025,.94)*(.82*sunlight); }
    else { c*=.86+.16*sunlight;c*=mix(float3(1),float3(1.015,1.005,.985),sunlight); } }
  return float4(c,1);
}
fragment float4 sky(O in [[stage_in]]) {
  float t=smoothstep(0.0,1.0,in.uv.y);
  return float4(mix(float3(.48,.69,.82),float3(.84,.89,.88),t),1);
}
"""
let library=try device.makeLibrary(source:shader,options:nil)
func pipeline(flat:Bool,samples:Int,background:Bool=false)throws->MTLRenderPipelineState {
  let d=MTLRenderPipelineDescriptor();d.vertexFunction=library.makeFunction(name:flat ? "flat":"terrain");d.fragmentFunction=library.makeFunction(name:background ? "sky":"ink")
  d.colorAttachments[0].pixelFormat = .rgba8Unorm_srgb;d.depthAttachmentPixelFormat = .depth32Float;d.rasterSampleCount=samples
  return try device.makeRenderPipelineState(descriptor:d)
}
let terrainPipeline=try pipeline(flat:false,samples:4), flatPipeline=try pipeline(flat:true,samples:1)
let skyPipeline=try pipeline(flat:true,samples:4,background:true)
let skyDepthDescription=MTLDepthStencilDescriptor();skyDepthDescription.isDepthWriteEnabled=false;skyDepthDescription.depthCompareFunction = .always
let skyDepth=device.makeDepthStencilState(descriptor:skyDepthDescription)!
let sd=MTLSamplerDescriptor();sd.minFilter = .linear;sd.magFilter = .linear;sd.mipFilter = .linear;sd.maxAnisotropy=16;sd.sAddressMode = .clampToEdge;sd.tAddressMode = .clampToEdge
let sampler=device.makeSamplerState(descriptor:sd)!
let dd=MTLDepthStencilDescriptor();dd.isDepthWriteEnabled=true;dd.depthCompareFunction = .lessEqual;let depthState=device.makeDepthStencilState(descriptor:dd)!
func loadTexture(_ variant:String)throws->MTLTexture {
  let levels=source.variants[variant]!, astc=variant=="astc"
  let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:astc ? .astc_4x4_srgb:.rgba8Unorm_srgb,width:levels[0].width,height:levels[0].height,mipmapped:true)
  d.storageMode = .private;d.usage=[.shaderRead,.pixelFormatView]
  guard let texture=device.makeTexture(descriptor:d) else { throw Failure.invalid("Texture allocation") }
  try check(texture.mipmapLevelCount==levels.count,"Complete mip chain")
  for (index,l) in levels.enumerated() {
    let raw=try Data(contentsOf:root.appendingPathComponent(l.file));try check(raw.count==l.byteCount && digest(raw)==l.sha256,"Texture hash")
    let row=((astc ? ((l.width+3)/4)*16:l.width*4)+255)/256*256
    let rows=astc ? (l.height+3)/4:l.height
    let buffer=device.makeBuffer(length:row*rows,options:.storageModeShared)!
    if astc {
      try check(raw.prefix(4)==Data([0x13,0xab,0xa1,0x5c]) && raw[4]==4 && raw[5]==4 && raw[6]==1,"ASTC header")
      let width=Int(raw[7])|Int(raw[8])<<8|Int(raw[9])<<16,height=Int(raw[10])|Int(raw[11])<<8|Int(raw[12])<<16
      try check(width==l.width && height==l.height && raw.count==16+((l.width+3)/4)*rows*16,"ASTC block dimensions")
      raw.withUnsafeBytes { b in for y in 0..<rows { buffer.contents().advanced(by:y*row).copyMemory(from:b.baseAddress!.advanced(by:16+y*((l.width+3)/4)*16),byteCount:((l.width+3)/4)*16) } }
    } else {
      guard let src=CGImageSourceCreateWithData(raw as CFData,nil),let image=CGImageSourceCreateImageAtIndex(src,0,nil),image.width==l.width,image.height==l.height,
            let c=CGContext(data:buffer.contents(),width:l.width,height:l.height,bitsPerComponent:8,bytesPerRow:row,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure.invalid("PNG decode") }
      c.setBlendMode(.copy);c.draw(image,in:CGRect(x:0,y:0,width:l.width,height:l.height))
    }
    let command=queue.makeCommandBuffer()!,blit=command.makeBlitCommandEncoder()!
    blit.copy(from:buffer,sourceOffset:0,sourceBytesPerRow:row,sourceBytesPerImage:row*rows,sourceSize:MTLSize(width:l.width,height:l.height,depth:1),to:texture,destinationSlice:0,destinationLevel:index,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
    blit.endEncoding();command.commit();command.waitUntilCompleted();try check(command.status == .completed,"Texture upload")
  }
  return texture
}
let vertexData=try Data(contentsOf:root.appendingPathComponent("vertices.bin")),indexData=try Data(contentsOf:root.appendingPathComponent("indices.bin"))
try check(digest(vertexData)==source.verticesSHA256 && digest(indexData)==source.indicesSHA256,"Geometry hashes")
try check(vertexData.count==source.vertexCount*48 && indexData.count==source.indexCount*4,"Geometry layout")
let vertices=vertexData.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)! }
let indices=indexData.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)! }
func perspective(_ aspect:Float)->simd_float4x4 {
  let y:Float=1/tan(.pi/8),near:Float=1,far:Float=10000,z=far/(near-far)
  return simd_float4x4(columns:(SIMD4(y/aspect,0,0,0),SIMD4(0,y,0,0),SIMD4(0,0,z,-1),SIMD4(0,0,z*near,0)))
}
func lookAt(_ eye:SIMD3<Float>,_ target:SIMD3<Float>)->simd_float4x4 {
  let z=normalize(eye-target),x=normalize(cross(SIMD3<Float>(0,1,0),z)),y=cross(z,x)
  return simd_float4x4(columns:(SIMD4(x.x,y.x,z.x,0),SIMD4(x.y,y.y,z.y,0),SIMD4(x.z,y.z,z.z,0),SIMD4(-dot(x,eye),-dot(y,eye),-dot(z,eye),1)))
}
struct Target { var color:MTLTexture;var msaa:MTLTexture?;var depth:MTLTexture;var width:Int;var height:Int }
func target(_ width:Int,_ height:Int,_ samples:Int)->Target {
  let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm_srgb,width:width,height:height,mipmapped:false);d.storageMode = .private;d.usage = .renderTarget
  let c=device.makeTexture(descriptor:d)!
  var ms:MTLTexture?
  if samples>1 { d.textureType = .type2DMultisample;d.sampleCount=samples;ms=device.makeTexture(descriptor:d)! }
  d.pixelFormat = .depth32Float;let depth=device.makeTexture(descriptor:d)!
  return Target(color:c,msaa:ms,depth:depth,width:width,height:height)
}
func draw(_ t:Target,_ map:MTLTexture,_ flat:Bool,_ uniforms:VaryingUniforms)throws->Double {
  let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=t.msaa ?? t.color;pass.colorAttachments[0].loadAction = .clear
  pass.colorAttachments[0].clearColor=MTLClearColor(red:0.75,green:0.87,blue:0.95,alpha:1)
  pass.colorAttachments[0].storeAction=t.msaa == nil ? .store:.multisampleResolve;pass.colorAttachments[0].resolveTexture=t.msaa == nil ? nil:t.color
  pass.depthAttachment.texture=t.depth;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .dontCare;pass.depthAttachment.clearDepth=1
  let command=queue.makeCommandBuffer()!,e=command.makeRenderCommandEncoder(descriptor:pass)!
  e.setRenderPipelineState(flat ? flatPipeline:terrainPipeline);e.setDepthStencilState(depthState);e.setCullMode(.none)
  var u=uniforms;if materialLighting && !flat && (materialLightingAll || map !== maps["current"]) { u.mode.y=1 };if illustratedLighting && !flat && (illustratedLightingAll || map !== maps["current"]) { u.mode.y=2 };
  if illustratedLighting && !flat {
    e.setRenderPipelineState(skyPipeline);e.setDepthStencilState(skyDepth)
    e.setVertexBytes(&u,length:MemoryLayout<VaryingUniforms>.stride,index:1)
    e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
    e.setRenderPipelineState(terrainPipeline);e.setDepthStencilState(depthState)
  };e.setVertexBytes(&u,length:MemoryLayout<VaryingUniforms>.stride,index:1);e.setFragmentBytes(&u,length:MemoryLayout<VaryingUniforms>.stride,index:1)
  e.setFragmentTexture(map,index:0);e.setFragmentSamplerState(sampler,index:0)
  if flat { e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3) }
  else { e.setVertexBuffer(vertices,offset:0,index:0);e.drawIndexedPrimitives(type:.triangle,indexCount:source.indexCount,indexType:.uint32,indexBuffer:indices,indexBufferOffset:0) }
  e.endEncoding();command.commit();command.waitUntilCompleted();try check(command.status == .completed,"Terrain render")
  return (command.gpuEndTime-command.gpuStartTime)*1000
}
func save(_ texture:MTLTexture,_ file:String)throws {
  let row=texture.width*4;let buffer=device.makeBuffer(length:row*texture.height,options:.storageModeShared)!
  let command=queue.makeCommandBuffer()!,blit=command.makeBlitCommandEncoder()!
  blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:texture.width,height:texture.height,depth:1),to:buffer,destinationOffset:0,destinationBytesPerRow:row,destinationBytesPerImage:row*texture.height)
  blit.endEncoding();command.commit();command.waitUntilCompleted();try check(command.status == .completed,"Image readback")
  let data=Data(bytes:buffer.contents(),count:row*texture.height)
  let image=CGImage(width:texture.width,height:texture.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:row,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
  let output=CGImageDestinationCreateWithURL(root.appendingPathComponent(file) as CFURL,UTType.png.identifier as CFString,1,nil)!
  CGImageDestinationAddImage(output,image,nil);try check(CGImageDestinationFinalize(output),"PNG write")
}
var maps:[String:MTLTexture]=[:],stats:[String:[String:Any]]=[:]
for name in ["current","hd","astc"] {
  let start=Date();let texture=try loadTexture(name);maps[name]=texture
  stats[name]=["textureGPUBytes":texture.allocatedSize,"uploadSeconds":Date().timeIntervalSince(start),"mipLevels":texture.mipmapLevelCount,"basePNGOrASTCBytes":source.variants[name]![0].byteCount,"completeMipFileBytes":source.variants[name]!.reduce(0){$0+$1.byteCount}]
  print("Loaded \(name): \(texture.allocatedSize) GPU bytes")
}
let terrainTarget=target(1440,1000,4)
var times:[String:[Double]]=[:]
let peak=SIMD3<Float>(source.widthMetres*0.18,source.maxHeight*0.88,0)
let close=VaryingUniforms(matrix:perspective(1.44)*lookAt(peak+SIMD3(120,220,300),peak),crop:SIMD4(0,0,1,1),mode:SIMD4(1,0,0,0))
let wide=VaryingUniforms(matrix:perspective(1.44)*lookAt(SIMD3(420,900,1100),SIMD3(0,source.maxHeight*0.45,0)),crop:SIMD4(0,0,1,1),mode:SIMD4(1,0,0,0))
for round in 0..<25 {
  for offset in 0..<3 {
    let name=["current","hd","astc"][(round+offset)%3]
    let ms=try draw(terrainTarget,maps[name]!,false,close)
    if round>=5 { times[name,default:[]].append(ms) }
  }
}
for name in ["current","hd","astc"] {
  stats[name]!["medianRenderGPUMilliseconds"]=times[name]!.sorted()[times[name]!.count/2]
  _=try draw(terrainTarget,maps[name]!,false,close);try save(terrainTarget.color,"close-\(name).png")
  _=try draw(terrainTarget,maps[name]!,false,wide);try save(terrainTarget.color,"wide-\(name).png")
}
// Full-resolution GPU sampling also checks ASTC decoding on real hardware.
let mapTarget=target(4096,4096,1)
for name in ["current","hd","astc"] {
  _=try draw(mapTarget,maps[name]!,true,VaryingUniforms(matrix:matrix_identity_float4x4,crop:SIMD4(0,0,1,1),mode:SIMD4(0,0,0,0)))
  try save(mapTarget.color,"map-\(name).png")
}
let report:[String:Any]=["device":device.name,"variants":stats,"geometryGPUBytes":vertices.allocatedSize+indices.allocatedSize,"vertexCount":source.vertexCount,"triangleCount":source.indexCount/3,"renderSize":[1440,1000],"samples":4,"anisotropy":16,"timingNote":"20 interleaved warmed-up GPU frame samples per variant; render pass only, not full app or physical iPad performance.","nativeASTCUploadAndRendering":true,"materialLighting":materialLighting,"materialLightingAll":materialLightingAll,"illustratedLighting":illustratedLighting,"illustratedLightingAll":illustratedLightingAll]
let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:root.appendingPathComponent("gpu.json"))
print(String(data:data,encoding:.utf8)!)
