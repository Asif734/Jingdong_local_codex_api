import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_visual_matcher.dart';
import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const fixtures = 'test/fixtures/v34_discovery';
  late List<Map<String, dynamic>> provenance;
  late Directory root;
  late CaptureDatabase db;
  late CaptureEvidenceStore evidence;
  late CustomerMediaInventory inventory;
  late DateTime now;
  setUp(() async {
    provenance =
        (jsonDecode(await File('$fixtures/provenance.json').readAsString())[
                'frames'] as List)
            .cast<Map<String, dynamic>>();
    root = await Directory.systemTemp.createTemp('jd_v34_loading_');
    db = CaptureDatabase(storageRoot: root);
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
    await root.delete(recursive: true);
  });
  Future<Uint8List> image(int index, [String suffix = '']) =>
      File('$fixtures/${provenance[index]['name']}$suffix.png').readAsBytes();
  List<double> region(int index) => [
        for (final key in ['x', 'y', 'width', 'height'])
          (provenance[index]['expectedVideoRegion'][key] as num).toDouble()
      ];
  List<double> chat() => [
        for (final key in ['left', 'top', 'right', 'bottom'])
          (provenance[0]['chatRegion'][key] as num).toDouble()
      ];
  Future<bool> transition({Uint8List? after, List<double>? box}) async =>
      MediaVisualMatcher.loadingCardTransition(
          previousCard: await image(0, '-card'),
          currentCard: await image(1, '-card'),
          previousFrame: await image(0),
          currentFrame: after ?? await image(1),
          previousRegion: region(0),
          currentRegion: box ?? region(1),
          transcript: chat());
  Future<Uint8List> changedPrefix() async {
    final codec = await ui.instantiateImageCodec(await image(1));
    final decoded = (await codec.getNextFrame()).image;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawImage(decoded, ui.Offset.zero, ui.Paint());
    canvas.drawRect(const ui.Rect.fromLTWH(820, 460, 3, 3),
        ui.Paint()..color = const ui.Color(0xff00ff00));
    final picture = recorder.endRecording();
    final result = await picture.toImage(decoded.width, decoded.height);
    final bytes = (await result.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();
    result.dispose();
    picture.dispose();
    decoded.dispose();
    codec.dispose();
    return bytes;
  }

  Future<void> registerFrame(int index,
      {Uint8List? replacement, String? session}) async {
    final path = File('${root.path}/frame-$index.png');
    await path.writeAsBytes(replacement ?? await image(index));
    final manifest = File('${root.path}/frame-$index.json');
    final payload = ViewportEvidence({
      'evidenceId': 'frame-$index',
      'customer': 'buyer',
      'imagePath': path.path,
      'manifestPath': manifest.path,
      'capturedAtMs':
          now.add(Duration(milliseconds: index)).millisecondsSinceEpoch,
      'automationSessionId': session ?? db.currentAutomationSessionId,
      'chatRegion': provenance[index]['chatRegion'],
      'replyActivationAllowed': true,
      'capturePurpose': 'live_signal',
    });
    await manifest.writeAsString(payload.toJson());
    await evidence.record(payload);
  }

  Future<String> classify(int index) async {
    final r = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'frame-$index',
        observedAt: now.add(Duration(milliseconds: index)),
        senderAt: DateTime.utc(2026, 11, 5, 5, 51, 2),
        slot: 0,
        region: region(index),
        current: true);
    return inventory.classify(r, 'video',
        fingerprint: provenance[index]['visualFingerprint'],
        previewBytes: await image(index, '-card'),
        evidenceId: 'frame-$index',
        region: region(index));
  }

  Future<void> save(String receipt, int index,
      {bool placeholder = false, bool admit = false}) async {
    final parent = await inventory.resolveParent('buyer', receiptId: receipt);
    final c = CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: DateTime.now(),
        messages: [
          CapturedMessage(
              stableId: parent?.messageId ??
                  (placeholder ? 'media-pending:$receipt' : 'preview-$index'),
              direction: 'incoming',
              body: '[Customer sent media; acquisition pending.]',
              axPath: 'recorded card',
              sentAt: DateTime.utc(2026, 11, 5, 5, 51, 2),
              mediaReceiptId: receipt,
              media: placeholder
                  ? const []
                  : [
                      CapturedMedia(
                          type: 'image',
                          path:
                              '$fixtures/${provenance[index]['name']}-card.png',
                          captureSource: 'verified_media_preview',
                          isPartial: true,
                          isLoadingPreview: index == 0)
                    ])
        ]);
    if (admit) {
      await admitFixtureMedia(db,
          receiptId: receipt,
          messageId: c.messages.single.stableId,
          receivedAt: now,
          senderAt: c.messages.single.sentAt);
    }
    await db.saveCapture(c);
    await inventory.persist(c, verifiedAnchor: true, currentTaskOnly: true);
  }

  test(
      'recorded gray and loaded video retain the same card despite later read receipt',
      () async {
    expect(await MediaVisualMatcher.isLoadingCover(await image(0, '-card')),
        isTrue);
    expect(await MediaVisualMatcher.isLoadingCover(await image(1, '-card')),
        isFalse);
    expect(await transition(), isTrue);
  });
  test(
      'different preceding chat pixels or a moved card cannot authorize loading merge',
      () async {
    expect(await transition(after: await changedPrefix()), isFalse);
    expect(await transition(box: [.5, .39, .12, .26]), isFalse);
  });
  test(
      'loading preview upgrades one pending input without treating its holding as a formal answer',
      () async {
    await registerFrame(0);
    final first = await classify(0);
    await save(first, 0, placeholder: true, admit: true);
    await save(first, 0);
    await (await db.history).appendSlaFallbackSent(
        userId: 'buyer',
        messageId: 'red-cycle',
        reply: 'Please wait while I check.');
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'media-pending:$first'),
        isFalse);
    expect(await db.generationDue('buyer'), isFalse,
        reason: 'A loading preview is not ready for formal media analysis');
    // A same-clock candidate can have conservatively raised ambiguity.
    // Exact immutable-frame loading proof may resolve this specific card.
    await (await db.database).update(
        'customer_media_items', {'identity_ambiguous': 1},
        where: 'item_id=?', whereArgs: [first]);
    await registerFrame(1);
    final second = await classify(1);
    expect(second, first);
    await save(second, 1);
    await save(second, 1);
    final all = ((await (await db.history).read('buyer'))!['messages'] as List)
        .cast<Map>();
    final incoming = all.where((m) => m['direction'] == 'incoming').single;
    expect(incoming['id'], 'media-pending:$first');
    expect(incoming['service_evidence_revision'], 2);
    expect(
        (incoming['media'] as List).single['is_loading_preview'], isNot(true));
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    final pending = await inventory.pendingMediaForTask('buyer');
    expect(pending, hasLength(1));
    expect(pending.single['identityAmbiguous'], isFalse);
    expect(
        (await (await db.database)
            .query('customer_media_items', where: 'canonical_id IS NULL')),
        hasLength(1));
  });
  test(
      'same clock cannot merge a different card when transcript prefix changed',
      () async {
    await registerFrame(0);
    final first = await classify(0);
    await save(first, 0, placeholder: true, admit: true);
    await save(first, 0);
    await registerFrame(1, replacement: await changedPrefix());
    final second = await classify(1);
    expect(second, isNot(first));
  });
  test(
      'a direct original-image promotion keeps the same still-unanswered input',
      () async {
    CapturedConversation capture(CapturedMessage message) =>
        CapturedConversation(
            stableKey: 'buyer',
            customerName: 'buyer',
            customerExternalId: 'buyer',
            automationSessionId: db.currentAutomationSessionId,
            capturedAt: DateTime.now(),
            messages: [message]);
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: 'photo-frame',
        observedAt: now,
        senderAt: null,
        slot: 0,
        region: [.3, .4, .2, .2],
        current: true,
        occurrenceKey: 'actual-photo');
    await admitFixtureMedia(db,
        receiptId: receipt, messageId: 'picture', receivedAt: now);
    final partial = CapturedMessage(
        stableId: 'picture',
        direction: 'incoming',
        body: '[Partial image]',
        axPath: 'fixture',
        media: [
          CapturedMedia(
              type: 'image',
              path: '$fixtures/video-gray-after-reply-card.png',
              isPartial: true)
        ]);
    await db.saveCapture(capture(partial));
    await (await db.history).appendSlaFallbackSent(
        userId: 'buyer',
        messageId: 'image-red-cycle',
        reply: 'Please wait while I check.');
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
    expect(await db.isMessageFormallyAnswered('buyer', 'picture'), isFalse);
    final original = CapturedMessage(
        stableId: 'picture',
        direction: 'incoming',
        body: '[Original image]',
        axPath: 'fixture',
        media: [
          CapturedMedia(
              type: 'image',
              path: '$fixtures/video-cover-after-reply-card.png',
              captureSource: 'jd_image_cache')
        ]);
    expect(await (await db.history).promoteMedia('buyer', 'picture', original),
        isTrue);
    await db.saveCapture(capture(original));
    expect(await db.isMessageFormallyAnswered('buyer', 'picture'), isFalse);
    expect(await db.pendingMessageId('buyer'), 'picture');
  });
}
