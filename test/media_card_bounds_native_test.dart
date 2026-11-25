import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/image_original_locator.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  test('image and video cards survive uneven edges without inventing playback',
      () async {
    final source =
        File('macos/Runner/AccessibilityBridge.swift').readAsStringSync();
    final helpers = source.substring(
        source.indexOf('func looksLikeVideoThumbnail('),
        source.indexOf('func failedSendRetryDelay('));
    final directory = await Directory.systemTemp.createTemp('jd-card-bounds-');
    try {
      final script = File('${directory.path}/main.swift');
      await script.writeAsString('''import Cocoa
func jdMediaCondition(stage:String,id:String,expression:String,actual:[String:Any],threshold:[String:Any],passed:Bool)->[String:Any] {[:]}
$helpers
'''
          r'''
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let data=try Data(contentsOf:root.appendingPathComponent("loaded-card.ocr.json"))
let ocr=try JSONSerialization.jsonObject(with:data) as! [String:Any]
let image=NSBitmapImageRep(data:try Data(contentsOf:root.appendingPathComponent("loaded-card.png")))!.cgImage!
let chat=(ocr["chatRegion"] as! [String:NSNumber]).mapValues{$0.doubleValue}
let bands=jdIncomingMediaBands(observations:ocr["observations"] as! [[String:Any]],customer:"jd_41aeec7741d05",chatRegion:chat)
let regions=jdUnboundMediaRegions(image:image,chatRegion:chat,includeFullCards:true,messageBands:bands)
let cards=regions.filter{$0["proof"] as? String == "full_card_pixels"}
// The actual customer's full card is at x≈768, y≈884, width≈140, height≈303.
let found=cards.contains { row in
 let x=(row["x"] as! Double)*2880,y=(row["y"] as! Double)*1626
 let w=(row["width"] as! Double)*2880,h=(row["height"] as! Double)*1626
 return abs(x-768)<10 && abs(y-884)<10 && abs(w-140)<15 && abs(h-303)<20
}
if !found {print("Full received image was discarded: \(cards)");exit(1)}
if regions.contains(where:{$0["proof"] as? String == "explicit_play_overlay"}) {
 print("The product screenshot must not become a video");exit(1)
}
var verified=ocr
verified["physicalMediaRegions"]=cards
print(String(data:try JSONSerialization.data(withJSONObject:verified),encoding:.utf8)!)
// Both horizontal borders are searched, not fixed screen coordinates. Move a
// synthetic video card sideways and give its lower edge a seven-pixel slope.
for dx in [-4,0,4] {
 let c=CGContext(data:nil,width:1000,height:800,bitsPerComponent:8,bytesPerRow:4000,
  space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 c.translateBy(x:0,y:800);c.scaleBy(x:1,y:-1)
 c.setFillColor(CGColor(gray:247.0/255,alpha:1));c.fill(CGRect(x:0,y:0,width:1000,height:800))
 let x=240+dx
 c.setFillColor(CGColor(gray:233.0/255,alpha:1));c.beginPath()
 c.move(to:CGPoint(x:x,y:220));c.addLine(to:CGPoint(x:x+200,y:220))
 c.addLine(to:CGPoint(x:x+200,y:527));c.addLine(to:CGPoint(x:x,y:520));c.closePath();c.fillPath()
 c.setStrokeColor(CGColor(gray:1,alpha:1));c.setFillColor(CGColor(gray:1,alpha:1));c.setLineWidth(3)
 c.strokeEllipse(in:CGRect(x:x+81,y:341,width:38,height:38))
 c.beginPath();c.move(to:CGPoint(x:x+94,y:351));c.addLine(to:CGPoint(x:x+94,y:369))
 c.addLine(to:CGPoint(x:x+109,y:360));c.closePath();c.fillPath()
 let videoRegions=jdUnboundMediaRegions(image:c.makeImage()!,chatRegion:["left":0.2,"right":0.9,"top":0.15,"bottom":0.9],
  includeFullCards:true,messageBands:[0.24...0.85])
 if !videoRegions.contains(where:{$0["proof"] as? String == "full_card_pixels"}) {
  print("Video full border lost at horizontal offset \(dx)");exit(1)
 }
 if !videoRegions.contains(where:{$0["proof"] as? String == "explicit_play_overlay"}) {
  print("Video playback proof lost at horizontal offset \(dx)");exit(1)
 }
}
''');
      final compiled = await Process.run('swiftc', [
        '-O',
        '-module-cache-path',
        '${directory.path}/cache',
        script.path,
        '-o',
        '${directory.path}/probe',
      ]);
      expect(compiled.exitCode, 0,
          reason: '${compiled.stdout}\n${compiled.stderr}');
      final result = await Process.run('${directory.path}/probe', [
        Directory('test/fixtures/v104_media_bounds').absolute.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final verified = OcrInspection.fromMap(Map<String, Object?>.from(
          jsonDecode(result.stdout.toString().trim()) as Map));
      expect(
          ImageOriginalLocator.locate(verified, 'jd_41aeec7741d05',
              DateTime.utc(2026, 11, 24, 9, 29, 19)),
          isNotEmpty,
          reason: 'A complete native card must reach Dart cache acquisition');
    } finally {
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
