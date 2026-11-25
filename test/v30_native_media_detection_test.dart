import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'recorded upper play glyph is video while photo and circular controls are not',
      () async {
    final bridge =
        await File('macos/Runner/AccessibilityBridge.swift').readAsString();
    final begin = bridge.indexOf('func looksLikeVideoThumbnail(');
    final end = bridge.indexOf('\nfunc failedSendRetryDelay', begin);
    final function = bridge.substring(begin, end);
    final temp = await Directory.systemTemp.createTemp('v30_native_media_');
    addTearDown(() => temp.delete(recursive: true));
    final script = File('${temp.path}/media.swift');
    await script.writeAsString('''import AppKit
import Foundation
$function
func image(_ name:String)->CGImage {
 let url=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name)
 return CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL,nil)!,0,nil)!
}
precondition(looksLikeVideoThumbnail(image("upper-play-video.png")),"Recorded JD video has its triangle above the ring center")
precondition(!looksLikeVideoThumbnail(image("printer-photo-no-play.png")),"Printer photo must remain an image")
func control(_ kind:Int)->CGImage {
 let c=CGContext(data:nil,width:320,height:400,bitsPerComponent:8,bytesPerRow:1280,
    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 c.setFillColor(CGColor(gray:0.3,alpha:1));c.fill(CGRect(x:0,y:0,width:320,height:400))
 c.setStrokeColor(CGColor(gray:1,alpha:1));c.setLineWidth(3)
 let ring=CGRect(x:130,y:170,width:60,height:60)
 if kind != 4 {c.strokeEllipse(in:ring)}
 if kind==1 {c.setFillColor(CGColor(gray:1,alpha:1));c.fillEllipse(in:ring)}
 if kind==2 || kind==3 || kind==4 {
  c.setFillColor(CGColor(gray:1,alpha:1));c.beginPath()
  if kind==3 {c.move(to:CGPoint(x:160,y:200));c.addLine(to:CGPoint(x:160,y:230));c.addLine(to:CGPoint(x:185,y:215))}
  else {c.move(to:CGPoint(x:150,y:184));c.addLine(to:CGPoint(x:150,y:216));c.addLine(to:CGPoint(x:175,y:200))}
  c.closePath();c.fillPath()
 }
 return c.makeImage()!
}
precondition(!looksLikeVideoThumbnail(control(0)),"Ring alone is not playback evidence")
precondition(!looksLikeVideoThumbnail(control(1)),"White circular printer controls are not videos")
precondition(looksLikeVideoThumbnail(control(2)),"Centered JD play glyph remains supported")
precondition(looksLikeVideoThumbnail(control(3)),"Upper triangle is supported with ring and negative-space proof")
precondition(!looksLikeVideoThumbnail(control(4)),"White triangle without a contrast ring is insufficient")
print("PASS: recorded upper-triangle video plus photo/ring/disk/triangle negative controls")
''');
    final result = await Process.run('swift', [
      '-module-cache-path',
      '${temp.path}/cache',
      script.path,
      Directory('test/fixtures/v30_media').absolute.path
    ], environment: {
      if (Platform.environment['DEVELOPER_DIR'] == null)
        'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'
    });
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('PASS: recorded upper-triangle video'));
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(minutes: 2)));
}
