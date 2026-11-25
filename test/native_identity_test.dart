import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'native AX identity rules reject wrong sources, truncation and canonical rebinding',
      () async {
    final root = Directory.current;
    var sdk = File(Platform.resolvedExecutable).parent;
    while (!Directory('${sdk.path}/bin/cache/artifacts/engine').existsSync() &&
        sdk.parent.path != sdk.path) {
      sdk = sdk.parent;
    }
    final framework = Directory(
        '${sdk.path}/bin/cache/artifacts/engine/darwin-x64-release/FlutterMacOS.xcframework/macos-arm64_x86_64');
    expect(framework.existsSync(), isTrue,
        reason: 'Flutter macOS release framework must be available.');
    final temp = await Directory.systemTemp.createTemp('jd_native_identity_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}/acceptance.swift');
    await source.writeAsString(
        '${await File('${root.path}/macos/Runner/AccessibilityBridge.swift').readAsString()}\n${await File('${root.path}/test/native/sidebar_row_selection.swift').readAsString()}\n${await File('${root.path}/test/native/identity_acceptance.swift').readAsString()}');
    final architecture =
        (await Process.run('uname', ['-m'])).stdout.toString().trim();
    final environment = <String, String>{
      if (Platform.environment['DEVELOPER_DIR'] == null &&
          Directory('/Applications/Xcode.app/Contents/Developer').existsSync())
        'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'
    };
    final executable = '${temp.path}/identity-acceptance';
    final compile = await Process.run(
        'xcrun',
        [
          'swiftc',
          '-parse-as-library',
          '-target',
          '$architecture-apple-macos13.0',
          '-F',
          framework.path,
          '-framework',
          'FlutterMacOS',
          '-Xlinker',
          '-rpath',
          '-Xlinker',
          framework.path,
          source.path,
          '-o',
          executable
        ],
        environment: environment);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final checked = await Process.run(
        executable, ['${root.path}/test/fixtures/ax_identity/header.txt']);
    expect(checked.exitCode, 0, reason: '${checked.stdout}\n${checked.stderr}');
    expect(checked.stdout.toString(),
        contains('PASS: sanitized recorded JD AX fixture'));
    expect(checked.stdout.toString(), contains('no AX reads'));
    expect(checked.stdout.toString(),
        contains('PASS: sidebar geometry, unambiguous selection'));
    expect(checked.stdout.toString(), contains('PASS: direct target AX frame'));
  }, skip: !Platform.isMacOS, timeout: const Timeout(Duration(minutes: 2)));
}
