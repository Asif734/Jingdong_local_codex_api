import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('v50-current-service-account');
  late MacOSCaptureAdapter adapter;
  late Future<Map<String, Object?>> Function() read;
  late List<String> calls;
  Map<String, Object?> proof(String account) => {
        'verified': true,
        'account': account,
        'source': 'accessibility_account_header',
        'windowTitle': '$account-咚咚融合工作台',
        'windowTitleAccount': account,
        'pid': 123,
        'observedAtMs': 1000,
      };

  setUp(() {
    calls = [];
    read = () async => proof('格志打印机小耿');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect(call.method, 'readCurrentServiceAccount',
          reason: 'Reading the account must not inspect OCR or open a dialog.');
      return read();
    });
    adapter = MacOSCaptureAdapter(channel: channel);
  });
  tearDown(() async {
    await adapter.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('literal AX account is cached without hardcoded shop or staff name',
      () async {
    for (final account in ['格志打印机小耿', '其他店铺小林', 'Team agent_I1']) {
      read = () async => proof(account);
      final result = await adapter.readCurrentServiceAccount();
      expect(result['verified'], isTrue);
      expect(result['account'], account);
      expect(adapter.currentServiceAccount, account);
    }
    expect(calls, everyElement('readCurrentServiceAccount'));
  });

  test('failed or placeholder AX proof clears a previously verified account',
      () async {
    await adapter.readCurrentServiceAccount();
    for (final invalid in [
      {'verified': false, 'reason': 'jd_not_running'},
      {...proof('当前客服账号')},
      {...proof('格志打印机小耿'), 'source': 'ocr'},
      {...proof('格志打印机小耿'), 'windowTitle': '格志打印机小华-咚咚融合工作台'},
      {...proof('格志打印机小耿'), 'windowTitleAccount': '格志打印机小华'},
      {...proof('格志打印机小耿')}..remove('observedAtMs'),
    ]) {
      read = () async => Map<String, Object?>.from(invalid);
      final result = await adapter.readCurrentServiceAccount();
      expect(result['verified'], isFalse);
      expect(result['account'], isNull);
      expect(adapter.currentServiceAccount, isNull);
    }
  });

  test('native transport failure returns unverified and clears old identity',
      () async {
    await adapter.readCurrentServiceAccount();
    read = () async => throw PlatformException(code: 'native_ax_unavailable');
    final result = await adapter.readCurrentServiceAccount();
    expect(result['verified'], isFalse);
    expect(result['reason'], 'native_ax_unavailable');
    expect(adapter.currentServiceAccount, isNull);
  });

  test('an older delayed AX read cannot replace the newer operator account',
      () async {
    final old = Completer<Map<String, Object?>>();
    final entered = Completer<void>();
    read = () {
      entered.complete();
      return old.future;
    };
    final first = adapter.readCurrentServiceAccount();
    await entered.future;
    read = () async => proof('新账号小林');
    final latest = await adapter.readCurrentServiceAccount();
    expect(latest['account'], '新账号小林');
    old.complete(proof('旧账号小耿'));
    expect((await first)['verified'], isFalse);
    expect(adapter.currentServiceAccount, '新账号小林');
  });

  test('native header proof keeps exact spelling and requires both AX sources',
      () async {
    final source =
        await File('macos/Runner/AccessibilityBridge.swift').readAsString();
    final start = source.indexOf('func jdServiceAccountFromAXHeader(');
    final end = source.indexOf('\nprivate struct AXNode {', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final root =
        await Directory.systemTemp.createTemp('jd_v50_account_native_');
    addTearDown(() => root.delete(recursive: true));
    final unit = File('${root.path}/account.swift');
    await unit.writeAsString('import Foundation\n'
        '${source.substring(start, end)}\n'
        '${await File('test/native/v50_service_account_acceptance.swift').readAsString()}');
    final executable = '${root.path}/account-proof';
    final environment = {
      if (Platform.environment['DEVELOPER_DIR'] == null &&
          Directory('/Applications/Xcode.app/Contents/Developer').existsSync())
        'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer',
    };
    final compile = await Process.run(
        'xcrun', ['swiftc', '-parse-as-library', unit.path, '-o', executable],
        environment: environment);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final checked = await Process.run(executable, const []);
    expect(checked.exitCode, 0, reason: '${checked.stdout}\n${checked.stderr}');
    expect(checked.stdout, contains('PASS: literal AX service account proof'));
  }, skip: !Platform.isMacOS);
}
