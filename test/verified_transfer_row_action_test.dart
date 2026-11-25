import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('verified row chooses transfer action without a second name recognition',
      () async {
    final source =
        await File('macos/Runner/AccessibilityBridge.swift').readAsString();
    final start = source.indexOf('// BEGIN JDVerifiedTransferRowAction');
    expect(start, greaterThanOrEqualTo(0));
    final end = source.indexOf('// END JDVerifiedTransferRowAction', start);
    final helper = source.substring(start, end);
    final types = source.substring(
        source.indexOf('private struct TransferTextLine {'), start);
    final rows = source.substring(
        source.indexOf('private func transferAccountName('),
        source.indexOf('private func transferRowDiagnostics('));
    final normalize = source.substring(
        source.indexOf('private func compactTransferText('),
        source.indexOf('private func recognizeTransferText('));
    final identity = source.substring(
        source.indexOf('private func customerIdentityKey('),
        source.indexOf('private func cleanedRowCustomerIdentity('));
    final temp = await Directory.systemTemp.createTemp('jd-row-action-');
    try {
      final script = File('${temp.path}/test.swift');
      await script.writeAsString(
          'import Cocoa\nimport ApplicationServices\n$types\n$helper\n$rows\n$normalize\n$identity\n' +
              r'''
func image()->CGImage {
 let context=CGContext(data:nil,width:968,height:1012,bitsPerComponent:8,bytesPerRow:968*4,
  space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 return context.makeImage()!
}
func check(_ value:Bool,_ message:String){if !value{print(message);exit(1)}}
private let bounds=CGRect(x:100,y:80,width:484,height:506)
private let verified=TransferDialogSnapshot(windowID:7,bounds:bounds,image:image(),lines:[])
private let candidate=TransferAccountCandidate(name:"格志打印机文文（雯雯）",frame:CGRect(x:202,y:514,width:236,height:26),greenPixelEvidence:459,redPixelEvidence:0,rowBounds:CGRect(x:0,y:492,width:968,height:70))
private let medium=TransferTextLine(text:candidate.name,confidence:0.30,frame:candidate.frame)
private let boundary=TransferTextLine(text:candidate.name,confidence:0.25,frame:candidate.frame)
private let low=TransferTextLine(text:candidate.name,confidence:0.249,frame:candidate.frame)
check(transferAccountCandidates(in:TransferDialogSnapshot(windowID:7,bounds:bounds,image:image(),lines:[medium])).count==1,"0.30 must pass the requested 0.25 threshold")
check(transferAccountCandidates(in:TransferDialogSnapshot(windowID:7,bounds:bounds,image:image(),lines:[boundary])).count==1,"0.25 boundary must pass")
check(transferAccountCandidates(in:TransferDialogSnapshot(windowID:7,bounds:bounds,image:image(),lines:[low])).isEmpty,"below 0.25 must fail")
private let point=jdVerifiedTransferRowActionPoint(verified:verified,candidate:candidate,currentWindowID:7,currentBounds:bounds)
check(point != nil,"a previously verified row must not need another OCR identity")
check(abs(point!.x-(100+484*0.73))<0.01,"click the measured transfer area")
check(abs(point!.y-(80+527.0/2))<0.01,"click the verified row center")
check(point!.x<100+484*0.80,"never enter the far-right notes area")
private let moved=jdVerifiedTransferRowActionPoint(verified:verified,candidate:candidate,currentWindowID:7,currentBounds:bounds.offsetBy(dx:200,dy:40))
check(moved != nil && abs(moved!.x-point!.x-200)<0.01 && abs(moved!.y-point!.y-40)<0.01,"track same modal movement")
check(jdVerifiedTransferRowActionPoint(verified:verified,candidate:candidate,currentWindowID:8,currentBounds:bounds)==nil,"another modal cannot reuse the row")
check(jdVerifiedTransferRowActionPoint(verified:verified,candidate:candidate,currentWindowID:7,currentBounds:CGRect(x:100,y:80,width:600,height:506))==nil,"changed layout needs fresh first-stage inspection")
private let offline=TransferAccountCandidate(name:candidate.name,frame:candidate.frame,greenPixelEvidence:0,redPixelEvidence:1)
check(jdVerifiedTransferRowActionPoint(verified:verified,candidate:offline,currentWindowID:7,currentBounds:bounds)==nil,"first-stage offline target is never transferable")
print("Verified-row action checks passed")
''');
      final result = await Process.run('/usr/bin/swift', [
        '-module-cache-path',
        '${temp.path}/modules',
        script.path
      ], environment: {
        'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'
      });
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('Verified-row action checks passed'));
    } finally {
      await temp.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
