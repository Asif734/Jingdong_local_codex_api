import 'dart:io';
import 'dart:convert';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/capture/direct_reply_delivery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jd.canonical.identity.acceptance');
  late MacOSCaptureAdapter adapter;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) handle;
  setUp(() {
    calls = [];
    adapter = MacOSCaptureAdapter(channel: channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) {
      calls.add(c);
      return handle(c);
    });
  });
  tearDown(() async {
    await adapter.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  for (final actual in [
    'jd_abcl',
    'jd_abcI',
    'jd_abci',
    'JD_abc1',
    'ｊｄ_abc1',
    'jd_abc…',
    '',
    null
  ]) {
    test('full draft ID jd_abc1 cannot be changed to $actual before sending',
        () async {
      handle = (_) async => {'opened': true, 'customer': actual};
      final delivery = DirectReplyDelivery(adapter, record: (_, __) {});
      var validated = 0, attempts = 0;
      await expectLater(
          delivery.deliver(
              customer: 'jd_abc1',
              reply: 'Only for jd_abc1',
              canSend: () async {
                validated++;
                return true;
              },
              beforeSend: () async {
                attempts++;
                return {};
              }),
          throwsA(isA<PlatformException>()));
      expect(validated, 0);
      expect(attempts, 0);
      expect(calls.map((c) => c.method), ['openConversation']);
      expect(adapter.verifiedCustomerIdentity('jd_abc1'), 'jd_abc1');
    });
  }
  test('known IDs with matching text still require a positive opened flag',
      () async {
    handle = (_) async => {'customer': 'jd_abc1'};
    await expectLater(
        adapter.openConversation('jd_abc1'), throwsA(isA<PlatformException>()));
  });
  test(
      'foreign history cannot become context or be overwritten under a different AX ID',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_history_owner_');
    addTearDown(() => root.delete(recursive: true));
    final store = ConversationFileStore(root);
    final source = {'schema_version': 1, 'user_id': 'jd_abcl', 'messages': []};
    final file = File('${root.path}/${store.safeUserId('jd_abc1')}.json');
    await file.writeAsString(jsonEncode(source));
    await expectLater(store.read('jd_abc1'), throwsStateError);
    await expectLater(
        store.appendCapture(CapturedConversation(
            stableKey: 'customer:jd_abc1',
            customerName: 'jd_abc1',
            customerExternalId: 'jd_abc1',
            capturedAt: DateTime.now(),
            messages: [])),
        throwsStateError);
    expect(jsonDecode(await file.readAsString()), source);
  });
  test('an echoed requested ID cannot override a conflicting observed AX ID',
      () async {
    handle = (_) async =>
        {'opened': true, 'customer': 'jd_abc1', 'activeCustomerId': 'jd_abcl'};
    final delivery = DirectReplyDelivery(adapter, record: (_, __) {});
    await expectLater(
        delivery.deliver(
            customer: 'jd_abc1',
            reply: 'for jd_abc1',
            canSend: () async => true),
        throwsA(isA<PlatformException>()));
    expect(calls.map((c) => c.method), ['openConversation']);
  });
  test(
      'a conflicting native send identity remains uncertain instead of confirming delivery',
      () async {
    handle = (c) async => c.method == 'openConversation'
        ? {'opened': true, 'customer': 'jd_abc1'}
        : {'sent': true, 'customer': 'jd_abc1', 'activeCustomerId': 'jd_abcl'};
    final events = <String>[];
    final delivery =
        DirectReplyDelivery(adapter, record: (e, _) => events.add(e));
    await expectLater(
        delivery.deliver(
            customer: 'jd_abc1',
            reply: 'for jd_abc1',
            canSend: () async => true),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'send_unconfirmed')));
    expect(events, contains('delivery.failed'));
    expect(events, isNot(contains('delivery.direct_send_confirmed')));
  });
  test('a verified provisional row cannot be rebound to another customer',
      () async {
    var actual = 'jd_abc1';
    handle = (c) async => [
          {
            'customer': actual,
            'identitySource': 'active_ax',
            'rowKey': 'same-key',
            'rowToken': 'token'
          }
        ];
    await adapter.listConversationRows();
    expect(adapter.verifiedCustomerIdentity('pending-row:same-key'), 'jd_abc1');
    actual = 'jd_abcl';
    await expectLater(
        adapter.listConversationRows(),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'row_identity_conflict')));
    expect(adapter.verifiedCustomerIdentity('pending-row:same-key'), 'jd_abc1');
  });
  test(
      'verified full ID remains unchanged for open, validation, journal and send without OCR',
      () async {
    handle = (c) async {
      expect((c.arguments as Map)['expectedCustomer'], 'jd_abc1');
      switch (c.method) {
        case 'openConversation':
          return {
            'opened': true,
            'customer': 'jd_abc1',
            'identitySource': 'ax_header_toolbar'
          };
        case 'sendDraftOnce':
          return {'sent': true, 'customer': 'jd_abc1'};
        default:
          fail('Unexpected request ${c.method}');
      }
    };
    final order = <String>[];
    final delivery = DirectReplyDelivery(adapter, record: (e, d) {
      if (e == 'delivery.conversation_opened' ||
          e == 'delivery.direct_send_confirmed') {
        order.add(e);
      }
    });
    expect(
        await delivery.deliver(
            customer: 'jd_abc1',
            reply: 'Only for jd_abc1',
            canSend: () async {
              order.add('validate:jd_abc1');
              return true;
            },
            beforeSend: () async {
              order.add('journal:jd_abc1');
              return {};
            }),
        isTrue);
    expect(order, [
      'delivery.conversation_opened',
      'validate:jd_abc1',
      'journal:jd_abc1',
      'delivery.direct_send_confirmed'
    ]);
    expect(calls.map((c) => c.method), ['openConversation', 'sendDraftOnce']);
  });
}
