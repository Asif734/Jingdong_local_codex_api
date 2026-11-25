import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'native group reuse requires fresh identical label glyphs and owned modal',
      () async {
    final source =
        await File('macos/Runner/AccessibilityBridge.swift').readAsString();
    expect(source, contains('private func transferDialogReusingGroupLabel('));
    final types = source.substring(
        source.indexOf('private struct TransferTextLine {'),
        source.indexOf('private struct TransferAccountCandidate {'));
    final start =
        source.indexOf('private func transferDialogReusingGroupLabel(');
    final helper = source.substring(
        start, source.indexOf('\nprivate func captureTransferDialog(', start));
    final dir = await Directory.systemTemp.createTemp('jd-group-reuse-');
    try {
      final script = File('${dir.path}/test.swift');
      await script.writeAsString(
          'import Cocoa\nimport ApplicationServices\n$types\n$helper\n'
          r'''
func image(_ changed:Bool=false)->CGImage {
 let c=CGContext(data:nil,width:400,height:240,bitsPerComponent:8,bytesPerRow:1600,
   space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 c.setFillColor(red:1,green:1,blue:1,alpha:1);c.fill(CGRect(x:0,y:0,width:400,height:240))
 c.setFillColor(red:0,green:0,blue:0,alpha:1)
 for y in [52,176] {c.fill(CGRect(x:84,y:y,width:12,height:12))}
 if changed {for y in [52,176] {c.fill(CGRect(x:120,y:y,width:8,height:12))}}
 return c.makeImage()!
}
func check(_ condition:Bool,_ message:String) {if !condition {print(message);exit(1)}}
private let bounds=CGRect(x:100,y:100,width:400,height:240)
private let label=TransferTextLine(text:"默认咨询组 (0/35)",confidence:1,frame:CGRect(x:80,y:50,width:160,height:20))
private let old=TransferDialogSnapshot(windowID:7,bounds:bounds,image:image(),lines:[label])
private let fresh=TransferDialogSnapshot(windowID:7,bounds:bounds,image:image(),lines:[])
check(transferDialogReusingGroupLabel(fresh,old) != nil,"unchanged label must reuse")
private let changed=TransferDialogSnapshot(windowID:7,bounds:bounds,image:image(true),lines:[])
check(transferDialogReusingGroupLabel(changed,old) == nil,"changed glyphs need recognition")
private let different=TransferDialogSnapshot(windowID:8,bounds:bounds,image:image(),lines:[])
check(transferDialogReusingGroupLabel(different,old) == nil,"different modal must not reuse")
private let moved=TransferDialogSnapshot(windowID:7,bounds:bounds.offsetBy(dx:1,dy:0),image:image(),lines:[])
check(transferDialogReusingGroupLabel(moved,old) == nil,"moved geometry must not reuse")
print("4 native label-reuse checks passed")
''');
      final result = await Process.run('/usr/bin/swift', [
        '-module-cache-path',
        '${dir.path}/modules',
        script.path
      ], environment: {
        'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'
      });
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('4 native label-reuse checks passed'));
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
