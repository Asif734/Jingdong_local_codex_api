import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native timer parses exact AX values without any Vision/OCR path',
      () async {
    final source =
        await File('macos/Runner/AccessibilityBridge.swift').readAsString();
    final begin = source.indexOf('func jdParseRedClockAXText(');
    final end =
        source.indexOf('private func normalizedCustomerIdentity', begin);
    final parser = source.substring(begin, end);
    final readBegin = source.indexOf('  private func axRedClockReading(');
    final reader = source.substring(
        readBegin, source.indexOf('  func conversationRows()', readBegin));
    expect(reader, contains('node.value'));
    expect(reader, contains('node.frame'));
    expect(reader, isNot(contains('VNRecognizeTextRequest')));
    expect(source, isNot(contains('func unreadElapsedSeconds(')));
    final sendReaderStart =
        source.indexOf('  private func activeCustomerHasRedClock(');
    final sendReader = source.substring(sendReaderStart, readBegin);
    expect(sendReader,
        contains('exactCustomerIdentityMatches(active,expectedCustomer)'));
    expect(sendReader, contains('selectedRow(rows,pixels:pixels)'));
    expect(sendReader, contains('unreadBadgeEvidence(frame:frame'));
    expect(sendReader, isNot(contains('canonicalRowKeys')));
    final temp = await Directory.systemTemp.createTemp('jd_ax_clock_');
    try {
      final script = File('${temp.path}/check.swift');
      await script.writeAsString('''import Foundation
import CoreGraphics
$parser
assert(jdParseRedClockAXText("2秒") == 2)
assert(jdParseRedClockAXText("21") == 21)
assert(jdParseRedClockAXText("51秒") == 51)
assert(jdParseRedClockAXText("01:11") == 71)
assert(jdParseRedClockAXText("2l") == nil)
assert(jdParseRedClockAXText("2I") == nil)
assert(jdParseRedClockAXText("17:35") == nil)
assert(jdRedClockPill(CGRect(x:0,y:0,width:70,height:30)))
assert(!jdRedClockPill(CGRect(x:0,y:0,width:18,height:18)))
print("PASS: exact AX timer values and red pill geometry")
''');
      final result = await Process.run('swift', [
        '-module-cache-path',
        '${temp.path}/cache',
        script.path
      ], environment: {
        if (Platform.environment['DEVELOPER_DIR'] == null &&
            Directory('/Applications/Xcode.app/Contents/Developer')
                .existsSync())
          'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer',
      });
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('PASS: exact AX timer'));
    } finally {
      await temp.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(minutes: 1)));
}
