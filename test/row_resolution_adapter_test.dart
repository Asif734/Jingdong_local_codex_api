import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'capture and deadline callers cannot enqueue repeated native opens during row cooldown',
      () async {
    const channel = MethodChannel('jd.row-resolution-budget');
    final adapter = MacOSCaptureAdapter(channel: channel);
    var opens = 0;
    var unread = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'listConversationRows') {
        return [
          {
            'identitySource': 'row_anchor',
            'rowKey': 'a',
            'rowToken': 'a',
            'unread': unread
          }
        ];
      }
      if (call.method == 'openConversationRow') {
        opens++;
        return {'error': 'row_changed', 'openStage': 'row_reference'};
      }
      return {};
    });
    final observed = (await adapter.listConversationRows()).single.customer;
    await expectLater(
        adapter.openConversation(observed),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'row_changed')));
    for (var i = 0; i < 10; i++) {
      await adapter.listConversationRows();
      expect(adapter.rowResolutionDue(observed), isFalse);
      await expectLater(
          adapter.openConversation(observed),
          throwsA(isA<PlatformException>()
              .having((e) => e.code, 'code', 'row_resolution_deferred')));
    }
    expect(opens, 1);
    unread = false;
    await adapter.listConversationRows();
    unread = true;
    await adapter.listConversationRows();
    expect(adapter.rowResolutionDue(observed), isFalse,
        reason: 'Brief badge disappearance must not restart the retry budget.');
    adapter.resetRowResolution();
    expect(adapter.rowResolutionDue(observed), isTrue);
    await expectLater(
        adapter.openConversation(observed), throwsA(isA<PlatformException>()));
    expect(opens, 2);
    adapter.resetRowResolution();
    expect(adapter.rowResolutionDue(observed), isTrue);
    await adapter.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
