import Cocoa

let root=URL(fileURLWithPath:CommandLine.arguments[1])
let image=NSBitmapImageRep(data:try Data(contentsOf:root.appendingPathComponent("loaded.png")))!.cgImage!
let o=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("loaded.ocr.json"))) as! [String:Any]
let chat=o["chatRegion"] as! [String:Double]
let bands=jdIncomingMediaBands(observations:o["observations"] as! [[String:Any]],customer:"jd_hfzntrjsazsn",chatRegion:chat)
let cards=jdUnboundMediaRegions(image:image,chatRegion:chat,includeFullCards:true,messageBands:bands)
  .filter {$0["proof"] as? String=="full_card_pixels"}
precondition(cards.count==1,"Loaded white chat screenshot needs one whole card, got \(cards)")
let card=cards[0]
let rect=CGRect(x:(card["x"] as! Double)*Double(image.width),y:(card["y"] as! Double)*Double(image.height),
 width:(card["width"] as! Double)*Double(image.width),height:(card["height"] as! Double)*Double(image.height))
precondition(abs(rect.minX-768)<6 && abs(rect.maxX-903)<6 && abs(rect.minY-584)<8 && abs(rect.maxY-884)<8,"Whole white original boundary: \(rect)")
print("PASS whole card",rect)
if CommandLine.arguments.count>2 {
 let crop=image.cropping(to:rect.integral)!
 try NSBitmapImageRep(cgImage:crop).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
}

precondition(jdUnboundMediaRegions(image:image,chatRegion:chat,
  includeFullCards:true,messageBands:[]).allSatisfy{$0["proof"] as? String != "full_card_pixels"})
precondition(jdUnboundMediaRegions(image:image,chatRegion:chat,
  includeFullCards:true,messageBands:[bands[0].lowerBound...0.45])
    .allSatisfy{$0["proof"] as? String != "full_card_pixels"})
print("PASS ownership and clipped-boundary controls")

func synthetic(_ dark:Bool)->CGImage {
 let c=CGContext(data:nil,width:1000,height:900,bitsPerComponent:8,bytesPerRow:4000,
  space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 c.setFillColor(NSColor(white:247.0/255,alpha:1).cgColor);c.fill(CGRect(x:0,y:0,width:1000,height:900))
 c.setFillColor(NSColor(white:dark ? 0.2:1,alpha:1).cgColor);c.fill(CGRect(x:250,y:300,width:140,height:300))
 // Sparse internal ink and big blank areas cannot change the outer rectangle.
 c.setFillColor(NSColor.red.cgColor);c.fill(CGRect(x:290,y:410,width:45,height:20))
 return c.makeImage()!
}
for dark in [false,true] {
 let result=jdUnboundMediaRegions(image:synthetic(dark),chatRegion:["left":0.2,"right":0.8,"top":0.2,"bottom":0.85],includeFullCards:true,messageBands:[0.30...0.75])
 .filter{$0["proof"] as? String=="full_card_pixels"}
 precondition(result.count==1,"Synthetic outside card: \(result)")
 precondition(abs((result[0]["width"] as! Double)*1000-140)<6)
 precondition(abs((result[0]["height"] as! Double)*900-300)<6)
}
print("PASS sparse white and dark image controls")
