import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late Map<String, dynamic> fixture;
  const customer = 'jd_41aeec7741d05';
  const childId =
      'f06f645934fa60192cea210ab476578059bf54ba0cc6d0d7eaa74cc6c87f55af';
  const rootId =
      '12a3b32b60bc0562bfe3b033772e4bd7a551aeb0337220022a639185c4100637';
  Map<String, Object?> fixtureRow(String id) =>
      Map<String, Object?>.from((fixture['rows'] as List)
          .whereType<Map>()
          .firstWhere((r) => r['item_id'] == id));
  List<Map<String, Object?>> payload(Map row) =>
      (jsonDecode(row['media_json'] as String) as List)
          .map((m) => Map<String, Object?>.from(m as Map))
          .toList();
  setUp(() async {
    fixture = jsonDecode(
        await File('test/fixtures/v36_status/proven-image-alias-snapshot.json')
            .readAsString());
    temporary = await Directory.systemTemp.createTemp('jd_v36_proven_media_');
    db = CaptureDatabase(storageRoot: temporary);
    await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    inventory = CustomerMediaInventory(db);
  });
  tearDown(() async {
    await db.close();
    await temporary.delete(recursive: true);
  });
  Future<void> seed(List<Map<String, Object?>> rows,
      {Map<String, Object?>? history}) async {
    final sql = await db.database;
    for (final row in rows) {
      await sql.insert('customer_media_items', row);
    }
    if (history != null) {
      final store = await db.history;
      await store.conversationsDirectory.create(recursive: true);
      await File(
              '${store.conversationsDirectory.path}/${store.safeUserId(customer)}.json')
          .writeAsString(jsonEncode(history));
    }
  }

  Future<Map<String, Object?>> stored(String id) async =>
      (await (await db.database).query('customer_media_items',
              where: 'item_id=?', whereArgs: [id]))
          .single;
  CapturedConversation observation(List<Map<String, Object?>> media,
          {String receipt = childId}) =>
      CapturedConversation(
          stableKey: customer,
          customerName: customer,
          customerExternalId: customer,
          automationSessionId: db.currentAutomationSessionId,
          capturedAt: DateTime.now().toUtc(),
          messages: [
            CapturedMessage(
                stableId: 'media-pending:$receipt',
                direction: 'incoming',
                body: '[Customer sent media]',
                axPath: 'test:already-proven-canonical',
                mediaReceiptId: receipt,
                sentAt: DateTime.fromMillisecondsSinceEpoch(
                    fixtureRow(rootId)['sender_ms']! as int,
                    isUtc: true),
                media: media.map(CapturedMedia.fromMap).toList())
          ]);

  test(
      'recorded v35 canonical preview inherits its explicit child original without reviving business',
      () async {
    await seed(
        (fixture['rows'] as List)
            .map((m) => Map<String, Object?>.from(m as Map))
            .toList(),
        history: Map<String, Object?>.from(fixture['history'] as Map));
    expect((await stored(rootId))['state'], 'preview');
    await inventory.reconcileProvenMediaAliases(customer: customer);
    final repaired = await stored(rootId);
    expect(repaired['state'], 'ready');
    expect(repaired['message_id'], 'media-pending:$rootId');
    expect(payload(repaired).single['path'], endsWith('a3551e456f41b6d7.jpeg'));
    expect(repaired['first_seen_ms'], fixtureRow(childId)['first_seen_ms']);
    final unrelated = fixtureRow(
        '9df4a44c840075aeea4819ac11999f0b08a90ce84990fd31d03f90a046e5fb4a');
    expect(
        (await stored(unrelated['item_id']! as String))['canonical_id'], isNull,
        reason:
            'Matching original paths alone cannot establish another canonical edge');
    expect(await (await db.database).query('pending_customers'), isEmpty);
    expect(await db.unansweredWorkCounts(), isEmpty);
    final document = await (await db.history).read(customer);
    final canonical = (document!['messages'] as List)
        .whereType<Map>()
        .firstWhere((m) => m['id'] == 'media-pending:$rootId');
    expect((canonical['media'] as List).single['path'],
        endsWith('a3551e456f41b6d7.jpeg'));
    final before = jsonEncode(repaired);
    await inventory.reconcileProvenMediaAliases(customer: customer);
    expect(jsonEncode(await stored(rootId)), before,
        reason: 'A second status refresh is idempotent');
  });

  test(
      'an original arriving through a bound child promotes an unready root and late crop cannot downgrade it',
      () async {
    final root = fixtureRow(rootId);
    final child = {
      ...fixtureRow(childId),
      'state': 'pending',
      'media_json': '[]'
    };
    await seed([root, child]);
    final original = payload(fixtureRow(childId));
    await inventory.persist(observation(original),
        verifiedAnchor: true, notify: false);
    final ready = await stored(rootId);
    expect(ready['state'], 'ready');
    expect(ready['message_id'], 'media-pending:$rootId');
    expect(payload(ready).single['path'], original.single['path']);
    await inventory.persist(
        observation([
          {
            'type': 'image',
            'path': 'later-crop.png',
            'capture_source': 'verified_window_crop',
            'is_partial': true,
          }
        ]),
        verifiedAnchor: true,
        notify: false);
    expect((await stored(rootId))['state'], 'ready');
    expect(
        payload(await stored(rootId)).single['path'], original.single['path']);
    expect((await stored(childId))['canonical_id'], rootId);
  });

  test(
      'proven video aliases retain all frames and late audio in both SQL and history',
      () async {
    final video = <String, Object?>{
      'type': 'video',
      'path': 'owned.mp4',
      'capture_source': 'jd_video_cache',
      'is_partial': false
    };
    final first = <String, Object?>{
      'type': 'image',
      'path': 'frame-1.jpg',
      'capture_source': 'jd_video_frame_1fps',
      'is_partial': false
    };
    final second = {...first, 'path': 'frame-2.jpg'};
    final audio = <String, Object?>{
      'type': 'audio',
      'path': 'owned.wav',
      'capture_source': 'jd_video_audio_ffmpeg',
      'description': '[Video speech transcript (en-US): paper stops feeding]'
    };
    final root = {
      ...fixtureRow(rootId),
      'kind': 'video',
      'state': 'ready',
      'media_json': jsonEncode([video, first])
    };
    final child = {
      ...fixtureRow(childId),
      'kind': 'video',
      'state': 'superseded',
      'media_json': jsonEncode([video, second, audio])
    };
    final store = await db.history;
    await store.appendCapture(observation([video, first], receipt: rootId),
        historyOnly: true);
    await store.appendCapture(observation([video, second, audio]),
        historyOnly: true);
    await seed([root, child]);
    await inventory.reconcileProvenMediaAliases(customer: customer);
    expect(payload(await stored(rootId)).map((m) => m['path']).toSet(),
        {'owned.mp4', 'frame-1.jpg', 'frame-2.jpg', 'owned.wav'});
    final doc = await store.read(customer);
    final canonical = (doc!['messages'] as List)
        .whereType<Map>()
        .firstWhere((m) => m['id'] == 'media-pending:$rootId');
    expect(
        (canonical['media'] as List)
            .whereType<Map>()
            .map((m) => m['path'])
            .toSet(),
        {'owned.mp4', 'frame-1.jpg', 'frame-2.jpg', 'owned.wav'});
    final key = (await inventory.analyzableEvidenceKeys(customer))[rootId];
    expect(key, isNotNull);
    expect((await inventory.analyzableEvidenceKeys(customer))[childId], key);
  });

  for (final differentSlot in [false, true]) {
    test(
        'quality repair cannot cross ${differentSlot ? 'a second same-clock slot' : 'a genuine later send'}',
        () async {
      final root = fixtureRow(rootId);
      final other = {
        ...fixtureRow(childId),
        'item_id': 'independent-card',
        'canonical_id': null,
        'sender_ms': (root['sender_ms']! as int) + (differentSlot ? 0 : 60000),
        'slot': differentSlot ? 1 : 0
      };
      await seed([root, other]);
      await inventory.reconcileProvenMediaAliases(customer: customer);
      expect((await stored(rootId))['state'], 'preview');
      expect((await stored('independent-card'))['canonical_id'], isNull);
      expect(payload(await stored(rootId)).single['is_partial'], isTrue);
    });
  }

  test(
      'history merge never replaces an original photo with a late ordinary crop',
      () async {
    final store = await db.history;
    final original = payload(fixtureRow(childId));
    await store.appendCapture(observation(original, receipt: rootId),
        historyOnly: true);
    await store.appendCapture(
        observation([
          {
            'type': 'image',
            'path': 'late-cover.png',
            'capture_source': 'verified_window_crop',
            'is_partial': true
          }
        ], receipt: rootId),
        historyOnly: true);
    final doc = await store.read(customer);
    final message = (doc!['messages'] as List).whereType<Map>().single;
    expect((message['media'] as List).single['path'], original.single['path']);
    expect(
        (message['media_alternates'] as List).whereType<Map>().single['path'],
        'late-cover.png');
  });

  test(
      'one active loaded cover corrects an ordinary cached image but cannot replace real video assets',
      () {
    final cached = <String, Object?>{
      'type': 'image',
      'path': 'same-cover.jpg',
      'capture_source': 'jd_image_cache',
      'is_partial': false
    };
    final loading = <String, Object?>{
      'type': 'image',
      'path': 'gray.png',
      'capture_source': 'verified_media_preview',
      'is_partial': true,
      'is_loading_preview': true
    };
    final loaded = <String, Object?>{
      'type': 'image',
      'path': 'same-cover.jpg',
      'capture_source': 'verified_media_preview',
      'is_partial': true
    };
    final corrected = ConversationFileStore.mergeProvenMediaPayloads([
      [cached, loading],
      [loaded]
    ]);
    expect(corrected.media.single['capture_source'], 'verified_media_preview');
    expect(corrected.media.single['is_partial'], isTrue);
    expect(corrected.alternates.map((m) => m['path']), contains('gray.png'));
    final video = <String, Object?>{
      'type': 'video',
      'path': 'original.mp4',
      'capture_source': 'jd_video_cache'
    };
    final frame = <String, Object?>{
      'type': 'image',
      'path': 'frame.jpg',
      'capture_source': 'jd_video_frame_1fps'
    };
    final audio = <String, Object?>{
      'type': 'audio',
      'path': 'speech.wav',
      'capture_source': 'jd_video_audio_ffmpeg'
    };
    final original = ConversationFileStore.mergeProvenMediaPayloads([
      corrected.media,
      corrected.alternates,
      [video, frame, audio],
      [loading]
    ]);
    expect(original.media.map((m) => m['path']).toSet(),
        {'original.mp4', 'frame.jpg', 'speech.wav', 'same-cover.jpg'});
    expect(
        original.media.singleWhere((m) => m['path'] == 'original.mp4'), video);
    expect(original.media.singleWhere((m) => m['path'] == 'frame.jpg'), frame);
    expect(original.media.singleWhere((m) => m['path'] == 'speech.wav'), audio);
    expect(original.media.singleWhere((m) => m['path'] == 'same-cover.jpg'),
        loaded,
        reason:
            'The one loaded cover remains analysis input alongside all real video assets');
    expect(original.alternates.map((m) => m['path']).toSet(),
        {'same-cover.jpg', 'gray.png'});
    expect(
        original.alternates.singleWhere((m) => m['path'] == 'same-cover.jpg'),
        cached);
    expect(
        [...original.media, ...original.alternates]
            .where((m) => m['path'] == 'same-cover.jpg')
            .map((m) => m['capture_source'])
            .toSet(),
        {'jd_image_cache', 'verified_media_preview'},
        reason:
            'The active video cover and its prior cached-image observation preserve both proven semantics');
  });

  test(
      'only analyzable content changes wait evidence keys; loading and crop paths do not',
      () async {
    final root = {
      ...fixtureRow(rootId),
      'media_json': jsonEncode([
        {
          'type': 'image',
          'path': 'loading.png',
          'capture_source': 'verified_window_crop',
          'is_partial': true,
          'is_loading_preview': true,
        }
      ])
    };
    await seed([root]);
    expect(await inventory.analyzableEvidenceKeys(customer), isEmpty);
    final sql = await db.database;
    Future<void> crop(String path) => sql.update(
        'customer_media_items',
        {
          'media_json': jsonEncode([
            {
              'type': 'image',
              'path': path,
              'capture_source': 'verified_window_crop',
              'is_partial': true,
              'is_loading_preview': false,
            }
          ])
        },
        where: 'item_id=?',
        whereArgs: [rootId]);
    await crop('first-crop.png');
    final first = (await inventory.analyzableEvidenceKeys(customer))[rootId];
    expect(first, isNotNull);
    await crop('shifted-crop.png');
    expect((await inventory.analyzableEvidenceKeys(customer))[rootId], first);
    await sql.update('customer_media_items',
        {'media_json': jsonEncode(payload(fixtureRow(childId)))},
        where: 'item_id=?', whereArgs: [rootId]);
    expect((await inventory.analyzableEvidenceKeys(customer))[rootId],
        isNot(first));
  });
  test(
      'interleaved repair and exact-owner late speech retain frames and audio without touching a resend',
      () async {
    final video = <String, Object?>{
      'type': 'video',
      'path': 'owned.mp4',
      'capture_source': 'jd_video_cache',
      'is_partial': false
    };
    final frame1 = <String, Object?>{
      'type': 'image',
      'path': 'frame-1.jpg',
      'capture_source': 'jd_video_frame_1fps',
      'is_partial': false
    };
    final frame2 = {...frame1, 'path': 'frame-2.jpg'};
    final audio = <String, Object?>{
      'type': 'audio',
      'path': 'owned.wav',
      'capture_source': 'jd_video_audio_ffmpeg'
    };
    final root = {
      ...fixtureRow(rootId),
      'kind': 'video',
      'state': 'preview',
      'media_json': jsonEncode([video, frame1])
    };
    final child = {
      ...fixtureRow(childId),
      'kind': 'video',
      'media_json': jsonEncode([video, frame2, audio])
    };
    final resend = {
      ...fixtureRow(rootId),
      'item_id': 'genuine-resend',
      'message_id': 'media-pending:genuine-resend',
      'aliases_json': '[]',
      'sender_ms': (root['sender_ms']! as int) + 60000,
      'kind': 'video',
      'state': 'ready',
      'media_json': jsonEncode([video, frame1])
    };
    await seed([root, child, resend]);
    await admitFixtureMedia(db,
        customer: customer,
        receiptId: rootId,
        messageId: 'media-pending:$rootId',
        receivedAt: DateTime.now().toUtc());
    await db.saveCapture(observation([video, frame1], receipt: rootId));
    final before = (await inventory.analyzableEvidenceKeys(customer))[rootId];
    final results = await Future.wait<Object?>([
      inventory.reconcileProvenMediaAliases(customer: customer),
      inventory.updateProvenVideoDescription(customer, 'owned.mp4',
          '[Video speech transcript (en-US): paper does not move]',
          messageId: 'media-pending:$rootId', receiptId: rootId),
    ]);
    expect(results[1], greaterThan(0));
    final merged = payload(await stored(rootId));
    expect(merged.map((m) => m['path']).toSet(),
        {'owned.mp4', 'frame-1.jpg', 'frame-2.jpg', 'owned.wav'});
    expect(merged.firstWhere((m) => m['type'] == 'video')['description'],
        contains('paper does not move'));
    expect(
        payload(await stored('genuine-resend'))
            .firstWhere((m) => m['type'] == 'video')['description'],
        isNull);
    expect((await inventory.analyzableEvidenceKeys(customer))[rootId],
        isNot(before));
    expect(
        await inventory.updateProvenVideoDescription(customer, 'owned.mp4',
            '[Video speech transcript (en-US): paper does not move]',
            messageId: 'media-pending:$rootId', receiptId: rootId),
        0);
    expect(
        await inventory.updateProvenVideoDescription(
            customer, 'owned.mp4', 'foreign update',
            messageId: 'not-observed-in-this-session', receiptId: rootId),
        0);
  });
}
