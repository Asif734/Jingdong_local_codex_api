import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _DayDatabase extends CaptureDatabase {
  _DayDatabase(Directory root, this.day) : super(storageRoot: root);
  final String? day;
  @override
  String? get currentBusinessDayKey => day;
}

/// Records how many full inventory payloads the two eligibility hot paths
/// actually fetch, rather than inferring performance from final filtering.
class _ReadProbe implements DatabaseExecutor {
  _ReadProbe(this.delegate);
  final DatabaseExecutor delegate;
  final List<int> inventoryRowsRead = [];
  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) async {
    final rows = await delegate.rawQuery(sql, arguments);
    if (sql.contains('customer_media_items')) {
      inventoryRowsRead.add(rows.length);
    }
    return rows;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected database operation: $invocation');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'daily-buyer';
  const businessDay = '2026-11-10';
  // Midnight in the shop's calendar, independent of the test Mac's timezone.
  final start = DateTime.utc(2026, 11, 9, 16);
  late Directory root;
  late _DayDatabase db;
  late CustomerMediaInventory inventory;
  late File image;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v52_media_day_');
    db = _DayDatabase(root, businessDay);
    await db.beginAutomationSession(
        startedAt: start.subtract(const Duration(seconds: 1)));
    inventory = CustomerMediaInventory(db);
    image = await File('${root.path}/owned-image.png').writeAsBytes([1, 2, 3]);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  List<Map<String, Object?>> media() => [
        {
          'type': 'image',
          'path': image.path,
          'capture_source': 'jd_image_cache'
        }
      ];

  Future<String> insert(String receipt,
      {DateTime? senderAt,
      DateTime? firstSeen,
      String? messageId,
      String? canonical,
      List<String> aliases = const [],
      bool hasMedia = true,
      bool invalidPayload = false,
      String buyer = customer}) async {
    final id = messageId ??
        (senderAt == null
            ? 'legacy:$receipt'
            : CustomerMessageTime.incomingId(buyer, senderAt));
    await (await db.database).insert('customer_media_items', {
      'item_id': receipt,
      'customer': buyer,
      'sender_ms': senderAt?.millisecondsSinceEpoch,
      'slot': 0,
      'kind': 'image',
      'state': 'ready',
      'first_seen_ms': (firstSeen ?? senderAt ?? start).millisecondsSinceEpoch,
      // A late cache update must never become the message's daily clock.
      'last_seen_ms':
          start.add(const Duration(hours: 8)).millisecondsSinceEpoch,
      'message_id': id,
      'canonical_id': canonical,
      'identity_ambiguous': 0,
      'media_json': invalidPayload
          ? 'unrelated old payload'
          : jsonEncode(hasMedia ? media() : []),
      'aliases_json': jsonEncode(aliases),
    });
    return id;
  }

  Map<String, dynamic> message(String id, DateTime senderAt,
          {DateTime? capturedAt, String? receipt}) =>
      {
        'id': id,
        'direction': 'incoming',
        'body': '[Customer sent image]',
        'sent_at': senderAt.toIso8601String(),
        'captured_at': (capturedAt ?? senderAt).toIso8601String(),
        if (receipt != null) 'media_receipt_id': receipt,
        'media': media(),
      };

  test('daily hot paths fetch one owned family, not 243 old payloads',
      () async {
    for (var i = 0; i < 243; i++) {
      await insert('archive-$i',
          senderAt: start.subtract(Duration(days: 1, seconds: i)),
          invalidPayload: true);
    }
    final oldId = CustomerMessageTime.incomingId(
        customer, start.subtract(const Duration(hours: 1)));
    final current = await insert('today', senderAt: start);
    final before = await (await db.database).query('customer_media_items');
    final probe = _ReadProbe(await db.database);
    final keys =
        await inventory.analyzableEvidenceKeys(customer, executor: probe);
    final ready =
        await inventory.analysisReadyMessageIds(customer, executor: probe);
    expect(keys.keys, containsAll(['today', current]));
    expect(ready, containsAll(['today', current]));
    expect(probe.inventoryRowsRead, [1, 1]);
    final context = await inventory.context(customer,
        history: [
          message(oldId, start.subtract(const Duration(hours: 1)),
              capturedAt: start.add(const Duration(hours: 1))),
          message(current, start, receipt: 'today')
        ],
        before: start.add(const Duration(hours: 2)));
    expect(context.map((item) => item['mediaItemId']), ['today']);
    expect(await (await db.database).query('customer_media_items'), before,
        reason: 'Filtering must preserve every archive row unchanged.');
  });

  test('China midnight is inclusive, next midnight and yesterday are excluded',
      () async {
    final old = await insert('before-midnight',
        senderAt: start.subtract(const Duration(milliseconds: 1)));
    final today = await insert('at-midnight', senderAt: start);
    final tomorrow = await insert('next-midnight',
        senderAt: start.add(const Duration(days: 1)));
    await insert('other-customer', senderAt: start, buyer: 'other');
    final keys = await inventory.analyzableEvidenceKeys(customer);
    expect(keys.keys, contains(today));
    expect(keys.keys, isNot(contains(old)));
    expect(keys.keys, isNot(contains(tomorrow)));
    expect(keys.keys, isNot(contains('other-customer')));
  });

  test('message time keys outrank late first-seen and last-seen timestamps',
      () async {
    final oldClock = start.subtract(const Duration(hours: 1));
    final oldKey = CustomerMessageTime.incomingId(customer, oldClock);
    final currentKey = CustomerMessageTime.incomingId(customer, start);
    await insert('old-canonical', messageId: oldKey, firstSeen: start);
    await insert('old-alias',
        messageId: 'legacy-old', firstSeen: start, aliases: [oldKey]);
    await insert('today-alias',
        messageId: 'legacy-today', firstSeen: oldClock, aliases: [currentKey]);
    await insert('observed-today', firstSeen: start);
    // An actual sender clock remains authoritative over a contradictory alias.
    await insert('old-sender', senderAt: oldClock, aliases: [currentKey]);
    final keys = await inventory.analyzableEvidenceKeys(customer);
    expect(keys.keys, containsAll(['today-alias', 'observed-today']));
    expect(
        keys.keys,
        isNot(anyOf(contains('old-canonical'), contains('old-alias'),
            contains('old-sender'))));
    final context = await inventory.context(customer,
        history: [message('legacy-today', start)],
        before: start.add(const Duration(hours: 1)));
    expect(context.single['mediaItemId'], 'today-alias');
    expect(DateTime.parse(context.single['senderAt']! as String), start,
        reason: 'A verified time alias also owns context chronology.');
  });

  test('old canonical observations enrich only their exact daily root',
      () async {
    final today = await insert('today-root', senderAt: start, hasMedia: false);
    await insert('old-child',
        canonical: 'today-root',
        firstSeen: start.subtract(const Duration(days: 1)),
        aliases: ['exact-old-representation']);
    await insert('old-grandchild',
        canonical: 'old-child',
        firstSeen: start.subtract(const Duration(days: 2)));
    await insert('old-root', senderAt: start.subtract(const Duration(days: 1)));
    await insert('late-old-cache', canonical: 'old-root', firstSeen: start);
    final probe = _ReadProbe(await db.database);
    final keys =
        await inventory.analyzableEvidenceKeys(customer, executor: probe);
    final ready =
        await inventory.analysisReadyMessageIds(customer, executor: probe);
    expect(probe.inventoryRowsRead, [3, 3]);
    expect(keys.keys, containsAll([today, 'old-child', 'old-grandchild']));
    expect(ready, containsAll([today, 'exact-old-representation']));
    expect(keys.keys, isNot(contains('old-root')));
    expect(keys.keys, isNot(contains('late-old-cache')));
    final context = await inventory.context(customer,
        history: [message(today, start)],
        before: start.add(const Duration(hours: 1)));
    expect(context.map((item) => item['mediaItemId']), ['today-root']);
    expect(context.single['messageAliases'], isEmpty,
        reason:
            'Material observations do not become another customer message.');
  });

  test('null daily mode preserves legacy cross-date eligibility and context',
      () async {
    await db.close();
    db = _DayDatabase(root, null);
    await db.beginAutomationSession(
        startedAt: start.subtract(const Duration(days: 2)));
    inventory = CustomerMediaInventory(db);
    final oldClock = start.subtract(const Duration(days: 1));
    final old = await insert('old', senderAt: oldClock);
    final today = await insert('today', senderAt: start);
    expect(await inventory.analysisReadyMessageIds(customer),
        containsAll([old, today]));
    final context = await inventory.context(customer,
        history: [message(old, oldClock), message(today, start)],
        before: start.add(const Duration(hours: 1)));
    expect(context.map((item) => item['mediaItemId']), ['old', 'today']);
  });
}
