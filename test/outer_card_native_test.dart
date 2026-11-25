import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('white screenshot keeps its complete outside card boundary', () async {
    final bridge =
        await File('macos/Runner/AccessibilityBridge.swift').readAsString();
    final start = bridge.indexOf('func looksLikeVideoThumbnail(');
    final end = bridge.indexOf('\nfunc failedSendRetryDelay', start);
    final diagnostics = bridge.substring(
        bridge.indexOf('func jdMediaCondition('),
        bridge.indexOf('private func jdRecordMediaCondition('));
    final root = await Directory.systemTemp.createTemp('jd_outer_card_');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/test.swift');
    await file.writeAsString(
        'import Cocoa\n$diagnostics\n${bridge.substring(start, end)}\n${await File('test/native/outer_card.swift').readAsString()}');
    final compiled = await Process.run('swiftc', [
      '-O',
      '-module-cache-path',
      '${root.path}/cache',
      file.path,
      '-o',
      '${root.path}/check'
    ]);
    expect(compiled.exitCode, 0,
        reason: '${compiled.stdout}\n${compiled.stderr}');
    final result = await Process.run('${root.path}/check',
        [Directory('test/fixtures/v88_outer_card').absolute.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('PASS whole card'));
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(minutes: 2)));
}
