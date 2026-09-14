import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
private struct Failure:Error,CustomStringConvertible {var description:String}
@MainActor @main struct CartographyMediumTests {
 static var checks=0
 static func check(_ value:Bool,_ message:String)throws {checks+=1;guard value else{throw Failure(description:message)}}
 static let info = CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue
 static func fixture(at root:URL,latitudes:[Double]) throws -> LoadedCartography {
  let edges:[Double]=[0,1,2,3],side=CartographyAtlas.imageSize,core=CartographyAtlas.imageCoreSize,g=CartographyAtlas.gutter
  var tiles:[CartographyTile]=[],urls:[URL]=[]
  for row in 0..<3 { for column in 0..<3 {
   var pixels=[UInt8](repeating:255,count:side*side*4)
   for y in 0..<side {for x in 0..<side {
    let gx=min(3*core-1,max(0,column*core+x-g)),gy=min(3*core-1,max(0,row*core+y-g)),i=(y*side+x)*4
    pixels[i]=UInt8((gx/core)*70+20);pixels[i+1]=UInt8((gy/core)*70+30);pixels[i+2]=UInt8((gx/16+gy/16)%120+50)
   }}
   let data=Data(pixels),space=CGColorSpace(name:CGColorSpace.sRGB)!,provider=CGDataProvider(data:data as CFData)!
   let image=CGImage(width:side,height:side,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:side*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:info),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
   let url=root.appendingPathComponent("native-\(column)-\(row).png")
   let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
   CGImageDestinationAddImage(dest,image,nil);guard CGImageDestinationFinalize(dest) else{throw Failure(description:"PNG write")}
   let encoded=try Data(contentsOf:url),hash=SHA256.hash(data:encoded).map{String(format:"%02x",$0)}.joined()
   let bounds=GeoBounds(minLatitude:latitudes[row+1],minLongitude:edges[column],maxLatitude:latitudes[row],maxLongitude:edges[column+1])
   let t=MapTexture(file:url.lastPathComponent,width:side,height:side,byteCount:Int64(encoded.count),sha256:hash,bounds:bounds)
   tiles.append(CartographyTile(image:t,preview:t));urls.append(url)
  }}
  return LoadedCartography(metadata:CartographyAtlas(columns:3,rows:3,longitudeEdges:edges,latitudeEdges:latitudes,tiles:tiles),imageURLs:urls,previewURLs:urls)
 }
 static func draw(_ index:Int,_ atlas:LoadedCartography)throws->[UInt8] {
  let side=CartographyAtlas.mediumSize;var bytes=[UInt8](repeating:0,count:side*side*4)
  try bytes.withUnsafeMutableBytes {raw in
   let c=CGContext(data:raw.baseAddress,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:info)!
   try CartographyMediumDecoder.draw(tile:index,atlas:atlas,into:c)
  }
  return bytes
 }
 static func color(_ bytes:[UInt8],_ x:Int,_ y:Int)->[UInt8] {Array(bytes[((y*CartographyAtlas.mediumSize+x)*4)..<((y*CartographyAtlas.mediumSize+x)*4+4)])}
 static func fixedReductionChecks(at root:URL)throws {
  let side=CartographyAtlas.imageSize,core=CartographyAtlas.imageCoreSize,g=CartographyAtlas.gutter
  func sample(_ global:Int)->UInt8 {let x=min(2*core-1,max(0,global));return (x+11)%64<32 ? 245:10}
  var tiles:[CartographyTile]=[],urls:[URL]=[]
  for column in 0..<2 {
   var bytes=[UInt8](repeating:255,count:side*side*4)
   for y in 0..<side{for x in 0..<side{let value=sample(column*core+x-g),offset=(y*side+x)*4;for channel in 0..<3{bytes[offset+channel]=value}}}
   let image=CGImage(width:side,height:side,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:side*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:info),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
   let url=root.appendingPathComponent("stripe-\(column).png"),destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
   CGImageDestinationAddImage(destination,image,nil);guard CGImageDestinationFinalize(destination)else{throw Failure(description:"Stripe PNG write failed")}
   let data=try Data(contentsOf:url),hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
   let bounds=GeoBounds(minLatitude:53,minLongitude:-4.02+Double(column)*0.01,maxLatitude:53.01,maxLongitude:-4.02+Double(column+1)*0.01)
   let texture=MapTexture(file:url.lastPathComponent,width:side,height:side,byteCount:Int64(data.count),sha256:hash,bounds:bounds)
   tiles.append(CartographyTile(image:texture,preview:texture));urls.append(url)
  }
  let atlas=LoadedCartography(metadata:CartographyAtlas(columns:2,rows:1,longitudeEdges:[-4.02,-4.02+0.01,-4.02+0.02],latitudeEdges:[53.01,53],tiles:tiles),imageURLs:urls,previewURLs:urls)
  func expected(_ start:Int)->Int {
   let linear=(0..<4).reduce(0.0){total,offset in let s=Double(sample(start+offset))/255;return total+(s<=0.04045 ? s/12.92:pow((s+0.055)/1.055,2.4))}/4
   return Int(((linear<=0.0031308 ? linear*12.92:1.055*pow(linear,1/2.4)-0.055)*255).rounded())
  }
  var pages:[[UInt8]]=[]
  for column in 0..<2 {
   let page=try draw(column,atlas);pages.append(page)
   let delta=(0..<264).map{abs(Int(color(page,$0,132)[0])-expected(column*core-16+$0*4))}.max()!
   try check(delta==0,"Fixed4×4 linear-sRGB average drifted from independent source average: \(delta)")
   try check((0..<264).allSatisfy{x in color(page,x,132)[0]==color(page,x,132)[1] && color(page,x,132)[1]==color(page,x,132)[2]},"Grayscale reduction changed channel balance")
  }
  try check((0..<8).allSatisfy{x in color(pages[0],256+x,132)==color(pages[1],x,132)},"High-contrast shared gutter differs between independently decoded neighbours")
  let threeQuarterWhite=expected(18)
  try check(threeQuarterWhite>200 && threeQuarterWhite != 186,"The reference must average decoded linear colour, not encoded sRGB bytes")
 }
 static func main()async throws {
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("ridge-medium-proof-\(UUID().uuidString)")
  try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try?fm.removeItem(at:root)}
  let atlas=try fixture(at:root,latitudes:[3,2,1,0])
  var pages:[[UInt8]]=[];for i in 0..<9{pages.append(try draw(i,atlas))}
  let c=pages[4]
  try check(color(c,130,1)[1]==30,"Northern gutter must use north neighbour")
  try check(color(c,130,262)[1]==170,"Southern gutter must use south neighbour")
  try check(color(c,1,130)[0]==20,"Western gutter must use west neighbour")
  try check(color(c,262,130)[0]==160,"Eastern gutter must use east neighbour")
  try check(color(c,1,1)[0...1]==[20,30],"Northwest diagonal")
  try check(color(c,262,262)[0...1]==[160,170],"Southeast diagonal")
  try check(color(c,130,130)[0...1]==[90,100],"Target interior retains center tile")
  for row in 0..<3{for column in 0..<2{
   let left=pages[row*3+column],right=pages[row*3+column+1]
   var delta=0
   for y in 0..<264{for x in 0..<8{for channel in 0..<4{delta=max(delta,abs(Int(color(left,256+x,y)[channel])-Int(color(right,x,y)[channel])))}}}
   try check(delta<=1,"Horizontal neighbour gutter mismatch: \(delta)")
  }}
  for row in 0..<2{for column in 0..<3{
   let top=pages[row*3+column],bottom=pages[(row+1)*3+column]
   var delta=0
   for y in 0..<8{for x in 0..<264{for channel in 0..<4{delta=max(delta,abs(Int(color(top,x,256+y)[channel])-Int(color(bottom,x,y)[channel])))}}}
   try check(delta<=1,"Vertical neighbour gutter mismatch: \(delta)")
  }}
  try check(color(pages[0],0,0)[0...1]==[20,30],"True northwest coverage corner clamps nearest source")
  try check(color(pages[8],263,263)[0...1]==[160,170],"True southeast coverage corner clamps nearest source")
  try check(pages.allSatisfy{p in stride(from:3,to:p.count,by:4).allSatisfy{p[$0]==255}},"No transparent pixel holes in core or gutters")
  let nonuniform=try fixture(at:root,latitudes:[4,3,1,0]),n=try draw(4,nonuniform)
  try check(color(n,130,1)[1]==30 && color(n,130,262)[1]==170,"Nonuniform row heights preserve north/south neighbours")
  try check(color(n,130,130)[0...1]==[90,100],"Nonuniform rows preserve target core")
  var corrupted=nonuniform
  corrupted.metadata.tiles[0].image.sha256=String(repeating:"0",count:64)
  do{_=try draw(4,corrupted);throw Failure(description:"Integrity violation accepted")}catch is Failure{throw Failure(description:"Integrity violation accepted")}catch{checks+=1}
  let worker=Task{try Task.checkCancellation();return try draw(4,nonuniform)}
  worker.cancel()
  do{_=try await worker.value;throw Failure(description:"Cancelled decode accepted")}catch is CancellationError{checks+=1}
  try fixedReductionChecks(at:root)
  print("PASS medium decoder: \(checks) assertions; orientation, exact neighbour gutters, corners, outer edges, nonuniform rows, hash rejection, cancellation and phase-stable linear-sRGB reduction")
 }
}
