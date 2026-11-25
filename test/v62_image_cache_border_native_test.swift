import Cocoa

// Synthetic images and temporary files only. No AX, clipboard or customer UI.
@main
struct ImageCacheBorderTests {
  static func original(seed:Int=1)->CGImage {
    let w=480,h=1040
    let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,
      bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),
      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor(white:0.06,alpha:1).cgColor)
    context.fill(CGRect(x:0,y:0,width:w,height:h))
    for i in 0..<14 {
      let y=70+i*62
      context.setFillColor(NSColor(white:Double(40+(i*seed*17)%100)/255,alpha:1).cgColor)
      context.fill(CGRect(x:25+(i%3)*13,y:y,width:300+(i*seed*7)%85,height:32))
      context.setFillColor(NSColor(white:0.8,alpha:1).cgColor)
      for j in 0..<5 {
        context.fill(CGRect(x:40+j*52,y:y+8,width:12+(i+j)%12,height:4))
      }
    }
    return context.makeImage()!
  }
  static func preview(_ source:CGImage,gutter:Bool)->CGImage {
    let w=128,h=266
    let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,
      bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),
      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x:0,y:0,width:w,height:h))
    context.interpolationQuality = .high
    context.draw(source,in:gutter ? CGRect(x:8,y:6,width:120,height:260) : CGRect(x:0,y:0,width:w,height:h))
    return context.makeImage()!
  }
  static func main() throws {
    let image=original(),bordered=preview(image,gutter:true)
    precondition(jdMatchingCachedImagePreview(visible:image,original:image) != nil)
    let matched=jdMatchingCachedImagePreview(visible:bordered,original:image)
    precondition(matched != nil && matched!.borderNormalized)
    precondition(matched!.hashDistance<=8 && matched!.ratioDelta<=0.08)
    precondition(jdMatchingCachedImagePreview(visible:bordered,original:original(seed:9))==nil)
    let clipped=image.cropping(to:CGRect(x:0,y:300,width:480,height:600))!
    precondition(jdMatchingCachedImagePreview(visible:clipped,original:image)==nil)
    let blankContext=CGContext(data:nil,width:128,height:266,bitsPerComponent:8,
      bytesPerRow:512,space:CGColorSpaceCreateDeviceRGB(),
      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    blankContext.setFillColor(NSColor.white.cgColor)
    blankContext.fill(CGRect(x:0,y:0,width:128,height:266))
    precondition(jdMatchingCachedImagePreview(visible:blankContext.makeImage()!,original:image)==nil)
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let urls=["first.png","copy.png","other.png"].map {root.appendingPathComponent($0)}
    let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!
    try data.write(to:urls[0]);try data.write(to:urls[1])
    try NSBitmapImageRep(cgImage:original(seed:9)).representation(using:.png,properties:[:])!.write(to:urls[2])
    precondition(jdCachedImageOriginalsIdentical(Array(urls.prefix(2))))
    precondition(!jdCachedImageOriginalsIdentical([urls[0],urls[2]]))
    precondition(!jdCachedImageOriginalsIdentical([urls[0],root.appendingPathComponent("missing.png")]))
    print("v62 image cache border native checks passed")
  }
}
