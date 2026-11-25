import Cocoa

/// Synthetic pixels and pure production decisions only. No live collector,
/// accessibility requests, clipboard reads, windows or input events occur.
@main
struct MessageContextImageCopyTests {
  static let chat=["left":0.1,"right":0.9,"top":0.1,"bottom":0.9]
  static func target()->[String:Any] {[
    "pointX":0.308,"pointY":0.332,
    "header":["x":0.3,"y":0.3,"width":0.2,"height":0.02],
    "bodyTop":0.324,"bodyBottom":0.7,"chat":chat
  ]}
  static func image(seed:Int=0,popup:Bool=false,changed:Bool=false,outside:Bool=false)->CGImage {
    let width=200,height=200
    let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,
      bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),
      bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bytes=context.data!.assumingMemoryBound(to:UInt8.self)
    for y in 0..<height {for x in 0..<width {
      let at=(y*width+x)*4
      bytes[at]=UInt8((x+y+seed)%255);bytes[at+1]=UInt8((x*2+y+seed)%255)
      bytes[at+2]=UInt8((y*3+seed)%255);bytes[at+3]=255
      if popup && x>=120 && x<170 && y>=80 && y<150 {
        bytes[at]=240;bytes[at+1]=240;bytes[at+2]=240
      }
      if changed && x==30 && y==100 {bytes[at]=255;bytes[at+1]=0;bytes[at+2]=0}
      if outside && x==5 && y==5 {bytes[at]=255;bytes[at+1]=0;bytes[at+2]=0}
    }}
    return context.makeImage()!
  }
  static func main() {
    var opened=false,stopped=false,observations=0
    let menu=jdObserveDispatchedImageContextMenu(observe:{()->[Int] in
      observations+=1
      if observations==1 {stopped=true;return []}
      opened=true;return [61]
    },pause:{})
    precondition(stopped && opened && observations==2 && menu==61)
    var ambiguousPolls=0
    let ambiguous=jdObserveDispatchedImageContextMenu(observe:{()->[Int] in
      ambiguousPolls+=1;return [61,62]
    },pause:{})
    precondition(ambiguous==nil && ambiguousPolls==16)
    let size=CGSize(width:1000,height:1000)
    let parsed=JDMessageImageCopyTarget(target(),chat:chat,imageSize:size)!
    precondition(abs(parsed.point.x-0.308)<0.000001)
    precondition(abs(parsed.point.y-0.332)<0.000001)
    for (key,value) in [("pointX",0.65),("pointX",0.099),("pointY",0.31),("pointY",0.6),("pointY",Double.nan)] {
      var wrong=target();wrong[key]=value
      precondition(JDMessageImageCopyTarget(wrong,chat:chat,imageSize:size)==nil)
    }
    var wrongChat=target();wrongChat["chat"]=["left":0.2,"right":0.9,"top":0.1,"bottom":0.9]
    precondition(JDMessageImageCopyTarget(wrongChat,chat:chat,imageSize:size)==nil)
    var wrongBody=target();wrongBody["bodyTop"]=0.31
    precondition(JDMessageImageCopyTarget(wrongBody,chat:chat,imageSize:size)==nil)
    var outsideBody=target();outsideBody["bodyBottom"]=0.99
    precondition(JDMessageImageCopyTarget(outsideBody,chat:chat,imageSize:size)==nil)

    var imageHit=target()
    imageHit["pointX"]=0.39;imageHit["pointY"]=0.43
    imageHit["confirmedRegion"]=["x":0.382,"y":0.422,"width":0.2,"height":0.22]
    precondition(JDMessageImageCopyTarget(imageHit,chat:chat,imageSize:size) != nil)
    var outsideImage=imageHit;outsideImage["pointX"]=0.6
    precondition(JDMessageImageCopyTarget(outsideImage,chat:chat,imageSize:size)==nil)
    var neighboringMessage=imageHit
    neighboringMessage["confirmedRegion"]=["x":0.382,"y":0.422,"width":0.2,"height":0.4]
    precondition(JDMessageImageCopyTarget(neighboringMessage,chat:chat,imageSize:size)==nil)

    let specific=jdImageContextCopyChoice(labels:["复制链接","复制","复制图片"],enabled:[true,true,true])!
    precondition(specific.index==2 && specific.explicitImage)
    precondition(jdImageContextCopyChoice(labels:["Copy Image"],enabled:[true])!.explicitImage)
    precondition(!jdImageContextCopyChoice(labels:["复制"],enabled:[true])!.explicitImage)
    precondition(jdImageContextCopyChoice(labels:["复制图片","复制图片"],enabled:[true,true])==nil)
    precondition(jdImageContextCopyChoice(labels:["复制链接"],enabled:[true])==nil)
    precondition(jdImageContextCopyChoice(labels:["复制图片"],enabled:[false])==nil)
    precondition(jdImageContextCopyChoice(labels:["复制","播放"],enabled:[true,true])==nil)
    precondition(jdImageContextCopyChoice(labels:["复制图片","下载视频"],enabled:[true,true])==nil)
    precondition(jdImageContextCopyChoice(labels:["Copy Image","Play Video"],enabled:[true,true])==nil)
    precondition(jdImageContextMenuConfirmsImage(labels:["复制","保存图片"],enabled:[true,true]))
    precondition(jdImageContextCopyChoice(labels:["复制","图片另存为"],enabled:[true,true])!.explicitImage)
    precondition(!jdImageContextMenuConfirmsImage(labels:["复制","另存为"],enabled:[true,true]))
    precondition(!jdImageContextMenuConfirmsImage(labels:["Copy","Save Video"],enabled:[true,true]))
    precondition(!jdImageContextMenuConfirmsImage(labels:["保存图片"],enabled:[false]))

    let window=CGRect(x:100,y:100,width:1000,height:1000)
    let gutter=jdImageCopyDismissPoint(target:parsed,chat:chat,windowBounds:window,imageSize:size,
      menus:[CGRect(x:400,y:400,width:300,height:400)])!
    precondition(abs(gutter.x-208)<0.001 && gutter.y<100+chat["bottom"]!*1000)
    precondition(!CGRect(x:400,y:400,width:300,height:400).contains(gutter))
    precondition(jdImageCopyDismissPoint(target:parsed,chat:chat,windowBounds:window,imageSize:size,
      menus:[CGRect(x:100,y:100,width:250,height:900)])==nil)
    var closeHeader=target();closeHeader["pointX"]=0.128
    closeHeader["header"]=["x":0.12,"y":0.3,"width":0.2,"height":0.02]
    let noBlankGutter=JDMessageImageCopyTarget(closeHeader,chat:chat,imageSize:size)!
    precondition(jdImageCopyDismissPoint(target:noBlankGutter,chat:chat,windowBounds:window,imageSize:size,menus:[])==nil)
    precondition(!jdImageOriginalMayClose(ownerEpoch:62,requestedEpoch:61))
    precondition(jdImageOriginalMayClose(ownerEpoch:61,requestedEpoch:61))
    let blankContext=CGContext(data:nil,width:200,height:200,bitsPerComponent:8,bytesPerRow:800,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    blankContext.setFillColor(NSColor(white:0.97,alpha:1).cgColor)
    blankContext.fill(CGRect(x:0,y:0,width:200,height:200))
    let blank=blankContext.makeImage()!
    precondition(jdImageCopyGutterIsBlank(image:blank,normalizedPoint:CGPoint(x:0.2,y:0.4)))
    precondition(!jdImageCopyGutterIsBlank(image:image(),normalizedPoint:CGPoint(x:0.2,y:0.4)))
    precondition(jdImageCopyDismissPoint(target:parsed,chat:chat,windowBounds:window,imageSize:size,menus:[],liveImage:blank) != nil)

    let original=image(),same=image(),differentInvoice=image(seed:1)
    precondition(jdCompleteCopiedImageMatches(original,same))
    precondition(!jdCompleteCopiedImageMatches(original,differentInvoice))
    let fragment=original.cropping(to:CGRect(x:0,y:0,width:100,height:200))!
    precondition(!jdCompleteCopiedImageMatches(original,fragment))
    let png=NSBitmapImageRep(cgImage:original).representation(using:.png,properties:[:])!
    let tiff=NSBitmapImageRep(cgImage:original).representation(using:.tiff,properties:[:])!
    precondition(jdCompleteCopiedImageMatches(jdCompleteOriginalImage(png)!,jdCompleteOriginalImage(tiff)!))
    precondition(jdCompleteOriginalImage(Data(png.prefix(png.count/2)))==nil)

    let header=CGRect(x:0.3,y:0.3,width:0.2,height:0.02)
    let popup=CGRect(x:0.6,y:0.4,width:0.25,height:0.35)
    precondition(jdContextCopyPixelsMatch(source:original,live:image(popup:true),chat:chat,menu:popup,header:header))
    precondition(!jdContextCopyPixelsMatch(source:original,live:image(popup:true,changed:true),chat:chat,menu:popup,header:header))
    precondition(jdContextCopyPixelsMatch(source:original,live:image(popup:true,outside:true),chat:chat,menu:popup,header:header))
    precondition(!jdContextCopyPixelsMatch(source:original,live:original,chat:chat,
      menu:CGRect(x:0.25,y:0.25,width:0.4,height:0.4),header:header))
    precondition(!jdContextCopyPixelsMatch(source:original,live:original,
      chat:["left":Double.nan,"right":0.9,"top":0.1,"bottom":0.9],menu:popup,header:header))

    precondition(!jdContextCopiedImageCanComplete(knownImage:false,explicitImageAction:false,exactImageCacheMatch:false,verifiedVideoCover:false))
    precondition(jdContextCopiedImageCanComplete(knownImage:false,explicitImageAction:true,exactImageCacheMatch:false,verifiedVideoCover:false))
    precondition(jdContextCopiedImageCanComplete(knownImage:true,explicitImageAction:false,exactImageCacheMatch:false,verifiedVideoCover:false))
    precondition(jdContextCopiedImageCanComplete(knownImage:false,explicitImageAction:false,exactImageCacheMatch:true,verifiedVideoCover:false))
    precondition(!jdContextCopiedImageCanComplete(knownImage:true,explicitImageAction:true,exactImageCacheMatch:true,verifiedVideoCover:true))
    print("v61 context image copy native checks passed")
  }
}
