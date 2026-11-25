import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_identity.dart';
import 'package:jd_automation/storage/media_visual_matcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  final at = DateTime.utc(2026, 11, 4, 8, 37, 28);
  const oldBox = [
    .2666633725166321,
    .4783679246902466,
    .12147009372711182,
    .26016533374786377
  ];
  const newBox = [
    .24556228518486023,
    .38544929027557373,
    .14302334189414978,
    .263273149728775
  ];
  final oldBytes = File('test/fixtures/v30/second_video_original_card.png');
  final newBytes = File('test/fixtures/v30/second_video_crop.png');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('v30_card_identity_');
    db = CaptureDatabase(storageRoot: root);
    inventory = CustomerMediaInventory(db);
    await inventory.beginRun(at.subtract(const Duration(seconds: 1)));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  CapturedConversation capture(String id, String receipt,
          {bool video = false, bool preview = false, DateTime? clock}) =>
      CapturedConversation(
          stableKey: 'buyer',
          customerName: 'buyer',
          customerExternalId: 'buyer',
          capturedAt: at,
          messages: [
            CapturedMessage(
                stableId: id,
                direction: 'incoming',
                body: video
                    ? '[video original]'
                    : preview
                        ? '[video pending]'
                        : '[image]',
                sentAt: clock ?? at,
                axPath: 'owned-card',
                mediaReceiptId: receipt,
                media: video
                    ? const [
                        CapturedMedia(
                            type: 'video',
                            path: '/owned/video.mp4',
                            captureSource: 'jd_video_cache'),
                        CapturedMedia(
                            type: 'image',
                            path: 'test/fixtures/v30/second_video_frame.jpg',
                            captureSource: 'jd_video_frame_1fps')
                      ]
                    : [
                        CapturedMedia(
                            type: 'image',
                            path: oldBytes.path,
                            captureSource: preview
                                ? 'verified_media_preview'
                                : 'jd_image_cache',
                            isPartial: preview)
                      ])
          ]);
  Future<String> seedOriginal() async {
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'original-frame',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: oldBox,
        current: true);
    await inventory.classify(receipt, 'video',
        fingerprint: 'ff00112233445566',
        previewBytes: await oldBytes.readAsBytes(),
        evidenceId: 'original-frame',
        region: oldBox);
    final c = capture('original-message', receipt, video: true);
    await db.saveCapture(c);
    await inventory.persist(c, verifiedAnchor: true);
    return receipt;
  }

  test(
      'recorded same video card corresponds despite avatar margin and playback overlay',
      () async {
    final score = await MediaVisualMatcher.correspondenceScore(
        await newBytes.readAsBytes(), await oldBytes.readAsBytes(),
        ignorePlayOverlay: true);
    expect(score, isNotNull);
    expect(score!, lessThanOrEqualTo(.018),
        reason: 'Strict recorded card pixel error=$score');
  });
  test(
      'recorded changed crop reuses ready original without another pending context revision',
      () async {
    await seedOriginal();
    final revision = await inventory.revision('buyer');
    final observed = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'later-frame',
        observedAt: at.add(const Duration(seconds: 10)),
        senderAt: at,
        slot: 0,
        region: newBox,
        current: true);
    final bound = await inventory.classify(observed, 'video',
        fingerprint: '83c3fbf3fb830307',
        previewBytes: await newBytes.readAsBytes(),
        evidenceId: 'later-frame',
        region: newBox);
    expect(await inventory.canonicalMessageId(bound, customer: 'buyer'),
        'original-message');
    final rows = await (await db.database).query('customer_media_items',
        where: "customer='buyer' AND canonical_id IS NULL");
    expect(rows, hasLength(1));
    expect(rows.single['state'], 'ready');
    expect(rows.single['identity_ambiguous'], 0);
    expect(await inventory.revision('buyer'), revision);
  });
  test(
      'same video bytes in another visible card slot remain an independent send',
      () async {
    await seedOriginal();
    final observed = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'later-frame',
        observedAt: at.add(const Duration(seconds: 10)),
        senderAt: at,
        slot: 1,
        region: newBox,
        current: true);
    final bound = await inventory.classify(observed, 'video',
        fingerprint: '83c3fbf3fb830307',
        previewBytes: await newBytes.readAsBytes(),
        evidenceId: 'later-frame',
        region: newBox);
    expect(
        await inventory.canonicalMessageId(bound, customer: 'buyer'), isNull);
    final identity = await MediaIdentityResolver(await db.history).resolve(
        customer: 'buyer',
        kind: 'video',
        digest: 'same-asset',
        sentAt: at,
        observedAt: at.add(const Duration(seconds: 10)),
        mediaReceiptId: bound);
    expect(identity.reused, isFalse);
    expect(identity.id, isNot('original-message'));
  });
  test(
      'a known pending video also coalesces a proven second crop without a restart',
      () async {
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'waiting-frame',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: oldBox,
        current: true);
    await inventory.classify(receipt, 'video',
        fingerprint: 'ff00112233445566',
        previewBytes: await oldBytes.readAsBytes(),
        evidenceId: 'waiting-frame',
        region: oldBox);
    final preview = capture('waiting-card', receipt, preview: true);
    await db.saveCapture(preview);
    await inventory.persist(preview, verifiedAnchor: true);
    final before = await inventory.revision('buyer');
    final later = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'waiting-later',
        observedAt: at.add(const Duration(seconds: 2)),
        senderAt: at,
        slot: 0,
        region: newBox,
        current: true);
    final canonical = await inventory.classify(later, 'video',
        fingerprint: '83c3fbf3fb830307',
        previewBytes: await newBytes.readAsBytes(),
        evidenceId: 'waiting-later',
        region: newBox);
    expect(await inventory.canonicalMessageId(canonical, customer: 'buyer'),
        'waiting-card');
    expect(await inventory.revision('buyer'), before);
    expect(await inventory.pendingVideoForTask('buyer', 'waiting-card'),
        isNotNull);
    expect(
        await (await db.database).query('customer_media_items',
            where: "customer='buyer' AND canonical_id IS NULL"),
        hasLength(1));
  });
  test(
      'a previously ambiguous exact fork is repaired only after recorded pixel proof',
      () async {
    final original = await seedOriginal();
    final observed = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'legacy-frame',
        observedAt: at.add(const Duration(seconds: 5)),
        senderAt: at,
        slot: 0,
        region: newBox,
        current: true);
    final fork = await inventory.classify(observed, 'video',
        fingerprint: '83c3fbf3fb830307');
    expect(fork, isNot(original));
    await inventory.persist(capture('legacy-preview', fork, preview: true),
        verifiedAnchor: true);
    final before = await inventory.revision('buyer');
    final current = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'proven-frame',
        observedAt: at.add(const Duration(seconds: 10)),
        senderAt: at,
        slot: 0,
        region: newBox,
        current: true);
    final canonical = await inventory.classify(current, 'video',
        fingerprint: '83c3fbf3fb830307',
        previewBytes: await newBytes.readAsBytes(),
        evidenceId: 'proven-frame',
        region: newBox);
    expect(await inventory.canonicalMessageId(canonical, customer: 'buyer'),
        'original-message');
    expect(await inventory.canonicalMessageId(fork, customer: 'buyer'),
        'original-message');
    final roots = await (await db.database).query('customer_media_items',
        where: "customer='buyer' AND canonical_id IS NULL");
    expect(roots, hasLength(1));
    expect(jsonDecode(roots.single['aliases_json']! as String),
        contains('legacy-preview'));
    expect(await inventory.revision('buyer'), before);
  });
  test(
      'same frozen card survives corrected clock and image-to-video classification',
      () async {
    final oldClock = at.subtract(const Duration(seconds: 10));
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'immutable-frame',
        observedAt: at,
        senderAt: oldClock,
        slot: 0,
        region: oldBox,
        current: true);
    await inventory.classify(receipt, 'image',
        fingerprint: 'ff00112233445566',
        previewBytes: await oldBytes.readAsBytes(),
        evidenceId: 'immutable-frame',
        region: oldBox);
    final initial = capture('same-card-message', receipt, clock: oldClock);
    await db.saveCapture(initial);
    await inventory.persist(initial, verifiedAnchor: true);
    final beforeTypeCorrection = await inventory.revision('buyer');
    final corrected = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'immutable-frame',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: oldBox,
        current: true);
    final canonical = await inventory.classify(corrected, 'video',
        fingerprint: '83c3fbf3fb830307',
        previewBytes: await oldBytes.readAsBytes(),
        evidenceId: 'immutable-frame',
        region: oldBox);
    expect(await inventory.canonicalMessageId(canonical, customer: 'buyer'),
        'same-card-message');
    expect(await inventory.revision('buyer'), greaterThan(beforeTypeCorrection),
        reason:
            'Known video evidence immediately invalidates a prepared cover-only answer');
    expect(await inventory.pendingVideoForTask('buyer', 'same-card-message'),
        isNotNull);
    final identity = await MediaIdentityResolver(await db.history).resolve(
        customer: 'buyer',
        kind: 'video',
        digest: 'other-asset',
        sentAt: at,
        observedAt: at,
        mediaReceiptId: canonical,
        anchoredMessageId:
            await inventory.canonicalMessageId(canonical, customer: 'buyer'));
    expect(identity.id, 'same-card-message');
    expect(identity.clockRefined, isTrue);
  });
  test(
      'same-clock matching content without card geometry is not a binding proof',
      () async {
    await seedOriginal();
    final observed = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'later-frame',
        observedAt: at.add(const Duration(seconds: 10)),
        senderAt: at,
        slot: 0,
        region: newBox,
        current: true);
    final bound = await inventory.classify(observed, 'video',
        fingerprint: '83c3fbf3fb830307',
        previewBytes: await newBytes.readAsBytes());
    expect(bound, isNot(observed));
    expect(
        await inventory.canonicalMessageId(bound, customer: 'buyer'), isNull);
  });
  test('known original cannot claim a crop from a different sender clock',
      () async {
    await seedOriginal();
    final later = at.add(const Duration(seconds: 40));
    final observed = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'new-send-frame',
        observedAt: later,
        senderAt: later,
        slot: 0,
        region: newBox,
        current: true);
    final bound = await inventory.classify(observed, 'video',
        fingerprint: '83c3fbf3fb830307',
        previewBytes: await newBytes.readAsBytes(),
        evidenceId: 'new-send-frame',
        region: newBox);
    expect(
        await inventory.canonicalMessageId(bound, customer: 'buyer'), isNull);
  });
  test(
      'distinct receipt keeps identical file and identical displayed clock as separate sends',
      () async {
    await db.saveCapture(capture('visible-image:asset:1', 'first-receipt'));
    final identity = await MediaIdentityResolver(await db.history).resolve(
        customer: 'buyer',
        kind: 'image',
        digest: 'asset',
        sentAt: at,
        observedAt: at,
        mediaReceiptId: 'second-receipt');
    expect(identity.reused, isFalse);
    expect(identity.id, contains(':card:'));
  });
  test(
      'explicit canonical card corrects a clock without replacing message or answered cursor',
      () async {
    final old = capture('visible-image:asset:1', 'first-receipt',
        clock: at.subtract(const Duration(seconds: 10)));
    await db.saveCapture(old);
    await (await db.database).insert('answered_cursors',
        {'user_id': 'buyer', 'message_id': old.messages.single.stableId});
    final identity = await MediaIdentityResolver(await db.history).resolve(
        customer: 'buyer',
        kind: 'video',
        digest: 'new-original',
        sentAt: at,
        observedAt: at,
        mediaReceiptId: 'canonical-receipt',
        anchoredMessageId: old.messages.single.stableId);
    expect(identity.reused, isTrue);
    expect(identity.clockRefined, isTrue);
    expect(identity.id, old.messages.single.stableId);
    final m =
        ((await (await db.history).read('buyer'))!['messages'] as List).single;
    expect(DateTime.parse(m['sent_at']), at);
    expect(await db.answeredMessageId('buyer'), identity.id);
  });
  test('explicit canonical anchor wins over legacy duplicate receipt rows',
      () async {
    await db.saveCapture(capture('canonical-card', 'shared-legacy-receipt'));
    await db.saveCapture(capture('legacy-extra', 'shared-legacy-receipt',
        clock: at.add(const Duration(seconds: 10))));
    final identity = await MediaIdentityResolver(await db.history).resolve(
        customer: 'buyer',
        kind: 'video',
        digest: 'new-original',
        sentAt: at,
        observedAt: at,
        mediaReceiptId: 'shared-legacy-receipt',
        anchoredMessageId: 'canonical-card');
    expect(identity.reused, isTrue);
    expect(identity.id, 'canonical-card');
  });
  test(
      'ordinary cached cover can become video preview and original on one durable ID',
      () async {
    final first = capture('media-card', 'receipt');
    await db.saveCapture(first);
    await inventory.persist(first, verifiedAnchor: true);
    final pending = capture('media-card', 'receipt', preview: true);
    await db.saveCapture(pending);
    await inventory.persist(pending, verifiedAnchor: true);
    final mid =
        ((await (await db.history).read('buyer'))!['messages'] as List).single;
    expect((mid['media'] as List).single['capture_source'],
        'verified_media_preview');
    expect(
        await inventory.pendingVideoForTask('buyer', 'media-card'), isNotNull);
    final original = capture('media-card', 'receipt', video: true);
    await db.saveCapture(original);
    await inventory.persist(original, verifiedAnchor: true);
    final stored =
        ((await (await db.history).read('buyer'))!['messages'] as List).single;
    expect(stored['id'], 'media-card');
    final active = (stored['media'] as List).cast<Map>();
    final alternates = (stored['media_alternates'] as List).cast<Map>();
    expect(active.map((m) => m['path']).toSet(), {
      '/owned/video.mp4',
      'test/fixtures/v30/second_video_frame.jpg',
      oldBytes.path,
    });
    expect(
        active.singleWhere(
            (m) => m['path'] == '/owned/video.mp4')['capture_source'],
        'jd_video_cache');
    expect(
        active.singleWhere((m) => m['path'] == oldBytes.path)['capture_source'],
        'verified_media_preview');
    expect(alternates, hasLength(1));
    expect(alternates.single['path'], oldBytes.path);
    expect(alternates.single['capture_source'], 'jd_image_cache');
    expect(
        [...active, ...alternates]
            .where((m) => m['path'] == oldBytes.path)
            .map((m) => m['capture_source'])
            .toSet(),
        {'jd_image_cache', 'verified_media_preview'});
    expect(await inventory.pendingVideoForTask('buyer', 'media-card'), isNull);
    expect(await db.answeredMessageId('buyer'), isNull);
    expect(await db.pendingMessageId('buyer'), 'media-card');
  });
  test(
      'alias-only late preview retires duplicate without invalidating ready original revision',
      () async {
    final receipt = await seedOriginal();
    final canonical = await inventory.classify(receipt, 'video',
        fingerprint: 'ff00112233445566');
    final before = await inventory.revision('buyer');
    final aliases = await inventory.persist(
        capture('late-preview', canonical, preview: true),
        verifiedAnchor: true);
    expect(aliases, contains('late-preview'));
    expect(await inventory.revision('buyer'), before);
    final rows = await (await db.database).query('customer_media_items',
        where: "customer='buyer' AND canonical_id IS NULL");
    expect(rows.single['state'], 'ready');
    expect(jsonDecode(rows.single['aliases_json']! as String),
        contains('late-preview'));
  });
  test(
      'a current unfinished real video survives the cover answer acquisition floor',
      () async {
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'current-frame',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: oldBox,
        current: true);
    await inventory.classify(receipt, 'video', fingerprint: '00000000ffffffff');
    final pending = capture('pending-video', receipt, preview: true);
    await db.saveCapture(pending);
    await inventory.persist(pending, verifiedAnchor: true);
    expect(await inventory.acquisitionFloor('buyer'), at);
    expect(
        await inventory.previewWait(
            'buyer', 'pending-video', at.add(const Duration(seconds: 40))),
        Duration.zero);
    expect(await inventory.pendingVideoForTask('buyer', 'pending-video'),
        isNotNull,
        reason:
            'The eight-second preview delay is not proof of completed video analysis');
    await inventory.persist(capture('pending-video', receipt, video: true),
        verifiedAnchor: true);
    expect(await inventory.acquisitionFloor('buyer'), isNull);
  });
  test('restart preserves only genuine unanswered video acquisition work',
      () async {
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'old-live-frame',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: oldBox,
        current: true);
    await inventory.classify(receipt, 'video', fingerprint: '00000000ffffffff');
    final pending = capture('old-live-video', receipt, preview: true);
    await db.saveCapture(pending);
    await inventory.persist(pending, verifiedAnchor: true);
    await inventory.beginRun(at.add(const Duration(minutes: 1)));
    expect(await inventory.acquisitionFloor('buyer'), at);
    await (await db.database).insert('answered_cursors',
        {'user_id': 'buyer', 'message_id': 'old-live-video'});
    expect(await inventory.acquisitionFloor('buyer'), isNull,
        reason: 'Old completed history cannot pull a new run backwards');
  });
  test(
      'historical and ambiguous media cannot extend the current acquisition window',
      () async {
    final historical = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'history-frame',
        observedAt: at.subtract(const Duration(minutes: 1)),
        senderAt: at.subtract(const Duration(minutes: 1)),
        slot: 0,
        region: oldBox,
        current: false);
    await inventory.classify(historical, 'video',
        fingerprint: '00000000ffffffff');
    final ambiguous = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'current-frame',
        observedAt: at,
        senderAt: at,
        slot: 0,
        region: oldBox,
        current: true);
    await inventory.classify(ambiguous, 'video',
        fingerprint: '00000000ffffffff');
    await inventory.classify(ambiguous, 'video',
        fingerprint: 'ffffffff00000000');
    expect(await inventory.acquisitionFloor('buyer'), isNull);
  });
}
