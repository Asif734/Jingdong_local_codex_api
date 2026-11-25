import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/media_visual_matcher.dart';
import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fixtures = 'test/fixtures/v37_media_card';
  late Directory temp;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late CaptureEvidenceStore evidence;
  late List<Map<String, dynamic>> frames;
  late DateTime now;
  final clock = DateTime.utc(2026, 11, 8, 2, 26, 1);
  setUp(() async {
    final provenance =
        jsonDecode(await File('$fixtures/provenance.json').readAsString());
    frames = (provenance['frames'] as List).cast<Map<String, dynamic>>();
    temp = await Directory.systemTemp.createTemp('jd_v37_card_');
    db = CaptureDatabase(storageRoot: temp);
    now = DateTime.now().toUtc();
    final session = await db.beginAutomationSession(
        startedAt: now.subtract(const Duration(seconds: 1)));
    evidence = CaptureEvidenceStore(db);
    await evidence.beginSession(
        sessionId: session,
        startedAt: now.subtract(const Duration(seconds: 1)));
    inventory = CustomerMediaInventory(db);
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<Uint8List> bytes(int index, {bool card = false}) =>
      File('$fixtures/${frames[index]['name']}${card ? '-card' : ''}.png')
          .readAsBytes();
  List<double> region(int i) => (frames[i]['region'] as List)
      .cast<num>()
      .map((n) => n.toDouble())
      .toList();
  List<double> chat() => [
        for (final k in ['left', 'top', 'right', 'bottom'])
          (frames[0]['chatRegion'][k] as num).toDouble()
      ];
  Future<void> register(int i, {String? suffix}) async {
    final id = '${frames[i]['name']}${suffix ?? ''}';
    final payload = ViewportEvidence({
      'evidenceId': id,
      'customer': 'buyer',
      'imagePath': File('$fixtures/${frames[i]['name']}.png').absolute.path,
      'manifestPath': '${temp.path}/$id.json',
      'capturedAtMs': now.add(Duration(seconds: i)).millisecondsSinceEpoch,
      'automationSessionId': db.currentAutomationSessionId,
      'capturePurpose': 'live_signal',
      'replyActivationAllowed': true,
      'chatRegion': frames[i]['chatRegion'],
    });
    await File('${temp.path}/$id.json').writeAsString(payload.toJson());
    await evidence.record(payload);
  }

  Future<String> classify(int i,
      {DateTime? senderAt, int slot = 0, String? suffix}) async {
    final id = '${frames[i]['name']}${suffix ?? ''}';
    final r = await inventory.observe(
        customer: 'buyer',
        evidenceId: id,
        observedAt: now.add(Duration(seconds: i)),
        senderAt: senderAt,
        slot: slot,
        region: region(i),
        current: true);
    return inventory.classify(r, frames[i]['kind'],
        fingerprint: frames[i]['fingerprint'],
        previewBytes: await bytes(i, card: true),
        evidenceId: id,
        region: region(i));
  }

  Future<void> save(String receipt, int i,
      {bool original = false, DateTime? senderAt, bool admit = false}) async {
    final parent = await inventory.resolveParent('buyer', receiptId: receipt);
    final c = CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: now,
        messages: [
          CapturedMessage(
              stableId: parent?.messageId ??
                  (original ? 'received-original' : 'media-pending:$receipt'),
              direction: 'incoming',
              body: original ? 'video acquired' : 'media pending',
              axPath: 'recorded video',
              sentAt: senderAt,
              mediaReceiptId: receipt,
              media: [
                if (original)
                  CapturedMedia(
                      type: 'video',
                      path: '${temp.path}/owned-video.mp4',
                      description: '[Video audio: no audio stream]'),
                if (original)
                  for (var n = 1; n <= 4; n++)
                    CapturedMedia(
                        type: 'image',
                        path: '$fixtures/old-sample-$n.jpg',
                        captureSource: 'jd_video_frame_1fps'),
                CapturedMedia(
                    type: 'image',
                    path: '$fixtures/${frames[i]['name']}-card.png',
                    captureSource: 'verified_media_preview',
                    isPartial: true,
                    isLoadingPreview: i == 0),
              ])
        ]);
    if (admit) {
      await admitFixtureMedia(db,
          receiptId: receipt,
          messageId: c.messages.single.stableId,
          receivedAt: now,
          senderAt: senderAt);
    }
    await db.saveCapture(c);
    await inventory.persist(c, verifiedAnchor: true, currentTaskOnly: true);
  }

  test('Nov8 gray card moving with caption is the same received video',
      () async {
    expect(
        await MediaVisualMatcher.loadingCardTransition(
            previousCard: await bytes(0, card: true),
            currentCard: await bytes(1, card: true),
            previousFrame: await bytes(0),
            currentFrame: await bytes(1),
            previousRegion: region(0),
            currentRegion: region(1),
            transcript: chat()),
        isTrue);
  });
  test('Nov8 headerless and inner crop continue the frozen video occurrence',
      () async {
    for (final pair in [
      [3, 4],
      [1, 5]
    ]) {
      expect(
          await MediaVisualMatcher.frozenCardContinuation(
              previousCard: await bytes(pair[0], card: true),
              currentCard: await bytes(pair[1], card: true),
              previousFrame: await bytes(pair[0]),
              currentFrame: await bytes(pair[1]),
              previousRegion: region(pair[0]),
              currentRegion: region(pair[1]),
              transcript: chat(),
              verifiedSenderClock: pair[1] == 5),
          isTrue,
          reason: '${frames[pair[0]]['name']} -> ${frames[pair[1]]['name']}');
    }
  });
  test(
      'Nov8 six derived observations retain first receipt and one business message',
      () async {
    await register(0);
    final first = await classify(0, senderAt: clock);
    await save(first, 0, senderAt: clock, admit: true);
    for (var i = 1; i < frames.length; i++) {
      await register(i);
      final id = await classify(i, senderAt: i == 4 ? null : clock);
      expect(id, first,
          reason: '${frames[i]['name']} must not create a business message');
      await save(id, i, original: i == 1, senderAt: i == 4 ? null : clock);
    }
    final roots = await (await db.database).query('customer_media_items',
        where: 'canonical_id IS NULL AND message_id IS NOT NULL');
    expect(roots, hasLength(1));
    expect(roots.single['message_id'], 'media-pending:$first');
    expect(roots.single['state'], 'ready');
    expect(roots.single['identity_ambiguous'], 0);
    final incoming =
        ((await (await db.history).read('buyer'))!['messages'] as List)
            .where((m) => m['direction'] == 'incoming');
    expect(incoming, hasLength(1));
    final media = (incoming.single['media'] as List).cast<Map>();
    expect(media.where((m) => m['type'] == 'video'), hasLength(1));
    expect(media.where((m) => m['capture_source'] == 'jd_video_frame_1fps'),
        hasLength(4));
    expect(media.where((m) => m['capture_source'] == 'verified_media_preview'),
        hasLength(1));
    expect(media.any((m) => m['is_loading_preview'] == true), isFalse);
  });
  test(
      'the same cover at another sender clock or separate same-second slot remains independent',
      () async {
    await register(1);
    final first = await classify(1, senderAt: clock);
    await save(first, 1, senderAt: clock, admit: true);
    await register(1, suffix: '-later');
    final later = await classify(1,
        senderAt: clock.add(const Duration(seconds: 1)), suffix: '-later');
    expect(later, isNot(first));
    await register(1, suffix: '-other-bubble');
    final other =
        await classify(1, senderAt: clock, slot: 1, suffix: '-other-bubble');
    expect(other, isNot(first));
    expect(other, isNot(later));
  });
  test('original video retains exactly one loaded cover alongside all samples',
      () {
    final result = ConversationFileStore.mergeProvenMediaPayloads([
      [
        {
          'type': 'image',
          'path': 'gray',
          'capture_source': 'verified_media_preview',
          'is_partial': true,
          'is_loading_preview': true
        }
      ],
      [
        {
          'type': 'image',
          'path': 'cover',
          'capture_source': 'jd_video_cover',
          'is_partial': true
        }
      ],
      [
        {'type': 'video', 'path': 'video'},
        for (var i = 0; i < 6; i++)
          {
            'type': 'image',
            'path': 'frame$i',
            'capture_source': 'jd_video_frame_1fps'
          }
      ],
    ]);
    expect(result.media, hasLength(8));
    expect(result.media.any((m) => m['path'] == 'cover'), isTrue);
    expect(result.media.any((m) => m['path'] == 'gray'), isFalse);
    expect(result.alternates.any((m) => m['path'] == 'gray'), isTrue);
  });
}
