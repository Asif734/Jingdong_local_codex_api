import Cocoa

/// Synthetic pixels only. This executable never instantiates the collector,
/// accesses AX, opens a window, reads customer data, or posts input events.
@main
struct ImageOriginalNativeTests {
  static func pattern(_ seed:Int)->CGImage {
    let width=240,height=320
    let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,
      bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bytes=context.data!.assumingMemoryBound(to:UInt8.self)
    for y in 0..<height {for x in 0..<width {
      let at=(y*width+x)*4
      bytes[at]=UInt8((x*(seed+2)/8+y/4)%220)
      bytes[at+1]=UInt8((x/3+y*(seed+3)/8)%230)
      bytes[at+2]=UInt8(((x/17+y/19+seed)%2)*180+30)
      bytes[at+3]=255
    }}
    return context.makeImage()!
  }
  static func chrome(_ centers:[CGPoint],scale:Int=1,rectangle:Bool=false)->CGImage {
    let width=400*scale,height=300*scale
    let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,
      bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bytes=context.data!.assumingMemoryBound(to:UInt8.self)
    for y in 0..<height {for x in 0..<width {
      let at=(y*width+x)*4
      let red=centers.contains { point in
        let dx=Double(x)/Double(scale)-point.x,dy=Double(y)/Double(scale)-point.y
        return rectangle ? abs(dx)<=6 && abs(dy)<=6 : dx*dx+dy*dy<=42.25
      }
      bytes[at]=255;bytes[at+1]=red ? 70:255;bytes[at+2]=red ? 60:255;bytes[at+3]=255
    }}
    return context.makeImage()!
  }
  static func main() {
    let original=pattern(1),different=pattern(9)
    precondition(jdOriginalImageMatches(visible:original,original:original))
    let fragment=original.cropping(to:CGRect(x:0,y:0,width:240,height:160))!
    precondition(jdOriginalImageMatches(visible:fragment,original:original))
    precondition(!jdOriginalImageMatches(visible:original,original:different))
    func product(_ seed:Int)->CGImage {
      let context=CGContext(data:nil,width:800,height:800,bitsPerComponent:8,
        bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:800,height:800))
      context.draw(pattern(seed),in:CGRect(x:220,y:240,width:160,height:240))
      return context.makeImage()!
    }
    let whiteProduct=product(1)
    let tightProduct=whiteProduct.cropping(to:CGRect(x:215,y:235,width:170,height:250))!
    precondition(jdOriginalImageMatches(visible:tightProduct,original:whiteProduct))
    precondition(!jdOriginalImageMatches(visible:tightProduct,original:product(9)))
    let blank=CGContext(data:nil,width:100,height:100,bitsPerComponent:8,
      bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),
      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    blank.setFillColor(NSColor.white.cgColor);blank.fill(CGRect(x:0,y:0,width:100,height:100))
    let image=blank.makeImage()!
    precondition(!jdOriginalImageMatches(visible:image,original:image))
    let png=NSBitmapImageRep(cgImage:original).representation(using:.png,properties:[:])!
    precondition(jdCompleteOriginalImage(png) != nil)
    precondition(jdCompleteOriginalImage(Data(png.prefix(png.count/2))) == nil)
    precondition(jdImageOriginalMayClose(ownerEpoch:53,requestedEpoch:53))
    precondition(!jdImageOriginalMayClose(ownerEpoch:54,requestedEpoch:53))
    precondition(jdImageOriginalMayClose(ownerEpoch:53,requestedEpoch:54))
    let ms:Int64=1794308102000
    let key="incoming-time:customer-a:2026-11-10T10:55:02Z"
    precondition(jdImageOriginalMessageBindingValid(customer:"customer-a",messageID:"legacy-kept-id",messageTimeKey:key,senderAtMs:ms))
    precondition(!jdImageOriginalMessageBindingValid(customer:"customer-a",messageID:"legacy-kept-id",messageTimeKey:"incoming-time:customer-a:2026-11-10T10:55:03Z",senderAtMs:ms))
    precondition(!jdImageOriginalMessageBindingValid(customer:"customer-a",messageID:"incoming-time:customer-a:2026-11-10T10:55:03Z",messageTimeKey:key,senderAtMs:ms))
    let unicodeKey="incoming-time:%E5%AE%A2%E6%88%B7%3A100%25:2026-11-10T10:55:02Z"
    precondition(jdImageOriginalMessageBindingValid(customer:"客户:100%",messageID:"legacy-kept-id",messageTimeKey:unicodeKey,senderAtMs:ms))
    precondition(!jdImageOriginalMessageBindingValid(customer:"客户:100%",messageID:"legacy-kept-id",messageTimeKey:"incoming-time:客户:100%:2026-11-10T10:55:02Z",senderAtMs:ms))
    let specialKey="incoming-time:customer%3Afoo%25:2026-11-10T10:55:02Z"
    precondition(jdImageOriginalMessageBindingValid(customer:"customer:foo%",messageID:specialKey,messageTimeKey:specialKey,senderAtMs:ms))
    let size=CGSize(width:400,height:300)
    let glyph=jdImageViewerCloseGlyph(image:chrome([CGPoint(x:18,y:18)]),windowSize:size)!
    precondition(abs(glyph.x-18)<1 && abs(glyph.y-18)<1)
    let retina=jdImageViewerCloseGlyph(image:chrome([CGPoint(x:18,y:18)],scale:2),windowSize:size)!
    precondition(abs(retina.x-36)<1 && abs(retina.y-36)<1)
    precondition(jdImageViewerCloseGlyph(image:chrome([CGPoint(x:18,y:80)]),windowSize:size)==nil)
    precondition(jdImageViewerCloseGlyph(image:chrome([CGPoint(x:18,y:18)],rectangle:true),windowSize:size)==nil)
    precondition(jdImageViewerCloseGlyph(image:chrome([CGPoint(x:18,y:18),CGPoint(x:40,y:18)]),windowSize:size)==nil)
    print("v53 original-image pixel checks passed")
  }
}
