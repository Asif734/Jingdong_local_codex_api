import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native Stop cancels queued and active work once and isolates restart',
      () async {
    final source = await File('macos/Runner/AccessibilityBridge.swift').readAsString();
    final start = source.indexOf('// BEGIN JDNativeWorkRegistry');
    final end = source.indexOf('// END JDNativeWorkRegistry');
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final temp = await Directory.systemTemp.createTemp('jd_native_stop_');
    addTearDown(() => temp.delete(recursive: true));
    final fixture = await File('test/v101_native_stop_test.swift').readAsString();
    final unit = File('${temp.path}/main.swift');
    await unit.writeAsString('import Foundation\n${source.substring(start, end)}\n$fixture');
    final sdk = await Process.run('xcrun', ['--sdk', 'macosx', '--show-sdk-path']);
    expect(sdk.exitCode, 0, reason: '${sdk.stderr}');
    final arch = await Process.run('uname', ['-m']);
    final result = await Process.run('xcrun', [
      'swift', '-sdk', sdk.stdout.toString().trim(),
      '-target', '${arch.stdout.toString().trim()}-apple-macosx11.0', unit.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout.toString(), contains('Native Stop cancellation:'));
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(minutes: 1)));
}
