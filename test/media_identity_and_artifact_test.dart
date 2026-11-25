import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/media_identity.dart';
import 'package:jd_automation/storage/processed_video_store.dart';
import 'package:jd_automation/domain/capture_models.dart';

void main() {
  late Directory root;
  late ConversationFileStore history;
  final now = DateTime.utc(2026, 11, 1, 4, 32);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_media_identity_');
    history = ConversationFileStore(root);
  });
  tearDown(() => root.delete(recursive: true));
  Future<void> add(String id, DateTime? clock, {String? turn}) async {
    await history.appendCapture(CapturedConversation(
        stableKey: 'a',
        customerName: 'a',
        customerExternalId: 'a',
        capturedAt: now,
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              body: 'media',
              sentAt: clock,
              axPath: 'fixture',
              observationTurnKey: turn,
              media: const [CapturedMedia(type: 'image', path: '/fixture.png')])
        ]));
  }

  test('ambiguous missing-clock originals remain distinct', () async {
    for (final turn in ['one', 'two']) {
      await history.appendCapture(CapturedConversation(
          stableKey: 'a',
          customerName: 'a',
          customerExternalId: 'a',
          capturedAt: now,
          messages: [
            CapturedMessage(
                stableId: 'visible-image:digest:observed:$turn',
                direction: 'incoming',
                body: 'image',
                axPath: 'fixture',
                observationTurnKey: turn,
                media: const [
                  CapturedMedia(
                      type: 'image',
                      path: '/fixture',
                      captureSource: 'jd_image_cache')
                ])
          ]));
    }
    final identity = await MediaIdentityResolver(history).resolve(
        customer: 'a',
        kind: 'image',
        digest: 'digest',
        sentAt: now.subtract(const Duration(seconds: 17)),
        observedAt: now.add(const Duration(seconds: 19)),
        turnKey: 'new');
    expect(identity.reused, isFalse);
    expect(identity.clockRefined, isFalse);
  });

  test(
      'unique cache original gets its missing clock without changing message ID after turn key moves',
      () async {
    await history.appendCapture(CapturedConversation(
        stableKey: 'a',
        customerName: 'a',
        customerExternalId: 'a',
        capturedAt: now,
        messages: [
          const CapturedMessage(
              stableId: 'visible-image:digest:observed:a',
              direction: 'incoming',
              body: 'image',
              axPath: 'fixture',
              observationTurnKey: 'old',
              media: [
                CapturedMedia(
                    type: 'image',
                    path: '/fixture',
                    captureSource: 'jd_image_cache')
              ])
        ]));
    final identity = await MediaIdentityResolver(history).resolve(
        customer: 'a',
        kind: 'image',
        digest: 'digest',
        sentAt: now.subtract(const Duration(seconds: 17)),
        observedAt: now.add(const Duration(seconds: 19)),
        turnKey: 'new');
    expect(identity.id, 'visible-image:digest:observed:a');
    expect(identity.clockRefined, isTrue);
    final later = await MediaIdentityResolver(history).resolve(
        customer: 'a',
        kind: 'image',
        digest: 'digest',
        sentAt: now.add(const Duration(seconds: 20)),
        observedAt: now.add(const Duration(seconds: 21)),
        turnKey: 'another');
    expect(later.reused, isFalse);
  });

  test(
      'missing/refined clock reuses the same observed image without moving its cursor',
      () async {
    await add('visible-image:digest:observed:a', null, turn: 'turn-a');
    final identity = await MediaIdentityResolver(history).resolve(
        customer: 'a',
        kind: 'image',
        digest: 'digest',
        sentAt: now,
        observedAt: now,
        turnKey: 'turn-a');
    expect(identity.id, 'visible-image:digest:observed:a');
    expect(identity.reused, isTrue);
    final document = await history.read('a');
    expect((document!['messages'] as List).single['sent_at'],
        now.toIso8601String());
    final resent = await MediaIdentityResolver(history).resolve(
        customer: 'a',
        kind: 'image',
        digest: 'digest',
        sentAt: now.add(const Duration(seconds: 1)),
        observedAt: now,
        turnKey: 'turn-a');
    expect(resent.reused, isFalse);
  });
  test('known clock followed by a missing clock does not duplicate an image',
      () async {
    await add('visible-image:digest:known', now, turn: 'turn-a');
    expect(
        (await MediaIdentityResolver(history).resolve(
                customer: 'a',
                kind: 'image',
                digest: 'digest',
                observedAt: now,
                turnKey: 'turn-a'))
            .reused,
        isTrue);
  });
  test('identical file resent at another verified clock remains a new message',
      () async {
    await add('visible-image:digest:known', now, turn: 'turn-a');
    expect(
        (await MediaIdentityResolver(history).resolve(
                customer: 'a',
                kind: 'image',
                digest: 'digest',
                sentAt: now.add(const Duration(seconds: 1)),
                observedAt: now,
                turnKey: 'turn-a'))
            .reused,
        isFalse);
  });
  test('different unread turns are not merged solely by identical file bytes',
      () async {
    await add('visible-image:digest:observed:a', null, turn: 'turn-a');
    expect(
        (await MediaIdentityResolver(history).resolve(
                customer: 'a',
                kind: 'image',
                digest: 'digest',
                observedAt: now,
                turnKey: 'turn-b'))
            .reused,
        isFalse);
  });
  test(
      'video frame/audio artifacts are reused after restart, missing artifacts rebuild',
      () async {
    var runs = 0;
    final media = File('${root.path}/frame.jpg');
    await media.writeAsBytes([1, 2, 3]);
    Future<CapturedMessage> create() async {
      runs++;
      await media.writeAsBytes([1, 2, 3]);
      return CapturedMessage(
          stableId: 'video',
          direction: 'incoming',
          body: 'audio evidence',
          axPath: 'cache',
          media: [CapturedMedia(type: 'image', path: media.path)]);
    }

    var cache = ProcessedVideoStore(Directory('${root.path}/artifacts'));
    await Future.wait([
      cache.getOrCreate('a', 'digest', create),
      cache.getOrCreate('a', 'digest', create)
    ]);
    expect(runs, 1);
    cache = ProcessedVideoStore(Directory('${root.path}/artifacts'));
    expect((await cache.getOrCreate('a', 'digest', create)).body,
        'audio evidence');
    expect(runs, 1);
    await media.delete();
    await cache.getOrCreate('a', 'digest', create);
    expect(runs, 2);
    await cache.getOrCreate('b', 'digest', create);
    expect(runs, 3);
  });
}
