import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/media_payload_upgrade.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

import 'helpers/media_admission_fixture.dart';

const _clear = <String, Object?>{
  'decoded': true,
  'width': 320,
  'height': 240,
  'touchesViewportEdge': false,
  'foregroundFraction': .7,
  'textureFraction': .25,
  'occupiedCellFraction': 1.0,
};
const _blank = <String, Object?>{
  'decoded': true,
  'width': 320,
  'height': 240,
  'touchesViewportEdge': false,
  'foregroundFraction': .01,
  'textureFraction': .001,
  'occupiedCellFraction': 0.0,
};

MediaPayloadVersion _version(String character,
        {bool partial = true,
        bool loading = false,
        bool original = false,
        bool available = true,
        bool video = false,
        Map<String, Object?> quality = _clear,
        String source = 'verified_window_crop'}) =>
    MediaPayloadVersion(
        sha256: List.filled(64, character).join(),
        isPartial: partial,
        isLoadingPreview: loading,
        verifiedOriginal: original,
        available: available,
        containsVideoMaterial: video,
        captureSource: source,
        captureQuality: quality);

MediaPayloadUpgradeDecision _decide(
        MediaPayloadVersion old, MediaPayloadVersion next,
        {bool answered = false}) =>
    MediaPayloadUpgrade.decide(
        sameMessageVerified: true,
        formallyAnswered: answered,
        candidate: next,
        previous: [old]);

Future<Uint8List> _picture(String kind,
    {int width = 320, int height = 240}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
  if (kind == 'toolbar') {
    for (var x = 8; x < width - 8; x += 30) {
      canvas.drawRect(ui.Rect.fromLTWH(x.toDouble(), height - 18.0, 10, 10),
          ui.Paint()..color = const ui.Color(0xff555555));
    }
  } else if (kind == 'photo') {
    for (var y = 0; y < height; y += 12) {
      for (var x = 0; x < width; x += 12) {
        canvas.drawRect(
            ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), 12, 12),
            ui.Paint()
              ..color = ui.Color.fromARGB(255, (x * 11 + y * 7) % 220,
                  (x * 3 + y * 13) % 220, (x * 17 + y * 5) % 220));
      }
    }
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'same owned identity does not turn different useful pixels into duplicates',
      () {
    final result = _decide(_version('a', quality: _blank), _version('b'));
    expect(result.kind, MediaPayloadUpgradeKind.upgradePendingRepresentation);
    expect(result.shouldStore, isTrue);
    expect(result.replaceExisting, isTrue);
    expect(result.completeOriginal, isFalse,
        reason: 'Clarity never makes a crop into its full original.');
  });

  test('same bytes and existing proof is an actual duplicate', () {
    final result = _decide(_version('a'), _version('a'));
    expect(result.kind, MediaPayloadUpgradeKind.exactDuplicate);
    expect(result.shouldStore, isFalse);
    expect(result.wakePending, isFalse);
  });

  test('same bytes with later original proof upgrades partial metadata', () {
    final result = _decide(
        _version('a'),
        _version('a',
            partial: false, original: true, source: 'jd_image_cache'));
    expect(result.kind, MediaPayloadUpgradeKind.upgradePendingRepresentation);
    expect(result.completeOriginal, isTrue);
  });

  test(
      'new hashes without measured quality gains never churn partial revisions',
      () {
    final first = _version('a', quality: const {});
    for (final char in ['b', 'c', 'd', 'e', 'f']) {
      final result = _decide(first, _version(char, quality: const {}));
      expect(result.shouldStore, isFalse);
      expect(result.reason, 'no_verified_capture_quality_gain');
    }
    expect(_decide(_version('a'), _version('b')).shouldStore, isFalse,
        reason:
            'A different equally clear viewport is not a material upgrade.');
  });

  test(
      'a clear crop cannot regress to clipped, loading, smaller or toolbar pixels',
      () {
    final previous = _version('a');
    for (final next in [
      _version('b', quality: {..._clear, 'touchesViewportEdge': true}),
      _version('b', loading: true),
      _version('b', quality: {..._clear, 'height': 100}),
      _version('b', quality: _blank),
    ]) {
      expect(_decide(previous, next).shouldStore, isFalse);
    }
  });

  test(
      'verified originals survive all later partials and alternative originals',
      () {
    final previous = _version('a', partial: false, original: true);
    for (final next in [
      _version('b'),
      _version('b', quality: {..._clear, 'width': 800, 'height': 600}),
      _version('b', partial: false, original: true),
    ]) {
      final result = _decide(previous, next);
      expect(result.kind, MediaPayloadUpgradeKind.preserveAuthoritative);
      expect(result.shouldStore, isFalse);
    }
  });

  test('completed replies and unverified ownership cannot reopen media work',
      () {
    final original = _version('b', partial: false, original: true);
    final answered = _decide(_version('a'), original, answered: true);
    expect(answered.kind, MediaPayloadUpgradeKind.alreadyAnswered);
    expect(answered.shouldStore, isFalse);
    expect(answered.wakePending, isFalse);
    expect(
        MediaPayloadUpgrade.decide(
            sameMessageVerified: false,
            formallyAnswered: false,
            candidate: original,
            previous: [_version('a')]).shouldStore,
        isFalse);
    expect(_decide(_version('a', video: true), original).shouldStore, isFalse);
  });

  test('unavailable files can be replaced but unusable candidate bytes cannot',
      () {
    expect(_decide(_version('a', available: false), _version('b')).shouldStore,
        isTrue);
    expect(
        _decide(_version('a'), _version('b', quality: const {'decoded': false}))
            .shouldStore,
        isFalse);
  });

  test(
      'bounded pixel statistics recognize blank/toolbar to real-content progress',
      () async {
    final blank = await _picture('blank');
    final toolbar = await _picture('toolbar');
    final photo = await _picture('photo');
    final measured = <String, Map<String, Object?>>{};
    for (final item in [
      ('blank', blank),
      ('toolbar', toolbar),
      ('photo', photo)
    ]) {
      measured[item.$1] =
          await computeImageCaptureQuality(item.$2, touchesViewportEdge: false);
      expect(measured[item.$1]!['decoded'], isTrue);
      expect(
          measured[item.$1]!['samplePixels']! as int, lessThanOrEqualTo(4096));
    }
    for (final old in ['blank', 'toolbar']) {
      final result = _decide(_version('a', quality: measured[old]!),
          _version('b', quality: measured['photo']!));
      expect(result.shouldStore, isTrue, reason: '$old -> photo');
      expect(result.completeOriginal, isFalse);
    }
    expect(measured['blank']!.containsKey('contentLeft'), isFalse);
    expect(
        (measured['photo']!['occupiedCellFraction']! as num).toDouble(),
        greaterThan(
            (measured['toolbar']!['occupiedCellFraction']! as num).toDouble()));
    expect(
        (measured['toolbar']!['contentBottom']! as num) -
            (measured['toolbar']!['contentTop']! as num),
        lessThan(.2),
        reason: 'A narrow toolbar cannot supply a photo-sized click target.');
    expect(
        (measured['photo']!['contentRight']! as num) -
            (measured['photo']!['contentLeft']! as num),
        greaterThan(.8));
    expect(
        _decide(_version('a', quality: measured['photo']!),
                _version('b', quality: measured['toolbar']!))
            .shouldStore,
        isFalse);
    expect(
        (await computeImageCaptureQuality(
            Uint8List.fromList([1, 2, 3])))['decoded'],
        isFalse);
  });

  test('one receipt upgrades to original while its text caption stays eligible',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v53_image_upgrade_');
    final db = CaptureDatabase(storageRoot: root);
    try {
      final at = DateTime.utc(2026, 11, 11, 4);
      await db.beginAutomationSession(startedAt: at);
      final inventory = CustomerMediaInventory(db);
      final sender = at.add(const Duration(seconds: 2));
      final observed = at.add(const Duration(seconds: 3));
      final id = CustomerMessageTime.incomingId('buyer', sender);
      final captionId = CustomerMessageTime.incomingId(
          'buyer', at.add(const Duration(seconds: 1)));
      final receipt = await inventory.observe(
          customer: 'buyer',
          evidenceId: 'owned-receipt-frame',
          observedAt: observed,
          senderAt: sender,
          slot: 0,
          region: [.3, .4, .2, .2],
          current: true);
      await inventory.classify(receipt, 'image');
      await admitFixtureMedia(db,
          receiptId: receipt,
          messageId: id,
          receivedAt: observed,
          senderAt: sender);
      final store = await db.history;
      final badBytes = await _picture('toolbar');
      final clearBytes = await _picture('photo');
      final badQuality =
          await computeImageCaptureQuality(badBytes, touchesViewportEdge: true);
      final clearQuality = await computeImageCaptureQuality(clearBytes,
          touchesViewportEdge: false);
      Future<CapturedMessage> image(
              Uint8List bytes, Map<String, Object?> quality,
              {bool original = false}) async =>
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              sender: 'buyer',
              body: '[Customer sent image]',
              sentAt: sender,
              mediaReceiptId: receipt,
              axPath: 'owned image fixture',
              media: [
                CapturedMedia(
                    type: 'image',
                    path: await store.saveMedia(
                        userId: 'buyer', filename: 'fixture.png', bytes: bytes),
                    captureSource:
                        original ? 'jd_image_cache' : 'verified_window_crop',
                    isPartial: !original,
                    captureQuality: quality)
              ]);
      CapturedConversation capture(List<CapturedMessage> messages, int step) =>
          CapturedConversation(
              stableKey: 'buyer',
              customerName: 'buyer',
              customerExternalId: 'buyer',
              automationSessionId: db.currentAutomationSessionId,
              capturedAt: observed.add(Duration(seconds: step)),
              messages: messages);
      final bad = await image(badBytes, badQuality);
      final first = capture([
        CapturedMessage(
            stableId: captionId,
            direction: 'incoming',
            sender: 'buyer',
            body: 'Actually I had one; this image shows it.',
            sentAt: at.add(const Duration(seconds: 1)),
            axPath: 'exact adjacent caption'),
        bad,
      ], 0);
      await db.saveCapture(first,
          activeIncomingIds: {captionId, id},
          mediaInputDependencies: {
            captionId: {receipt}
          },
          dependencyEvidenceId: 'owned-receipt-frame');
      await inventory.persist(first,
          verifiedAnchor: true, currentTaskOnly: true);
      expect(await db.generationDue('buyer'), isTrue,
          reason: 'The text caption is eligible independently of its image.');
      final firstDocument = (await store.read('buyer'))!;
      final initial = (firstDocument['messages'] as List)
          .cast<Map>()
          .singleWhere((m) => m['id'] == id);
      final revision = initial['service_evidence_revision']! as int;

      final clear = await image(clearBytes, clearQuality);
      expect(
          _decide(
                  MediaPayloadVersion(
                      sha256: sha256.convert(badBytes).toString(),
                      isPartial: true,
                      captureQuality: badQuality),
                  MediaPayloadVersion(
                      sha256: sha256.convert(clearBytes).toString(),
                      isPartial: true,
                      captureQuality: clearQuality))
              .replaceExisting,
          isTrue);
      expect(await store.promoteMedia('buyer', id, clear), isTrue);
      final second = capture([clear], 1);
      await db.saveCapture(second, activeIncomingIds: {id});
      await inventory.persist(second,
          verifiedAnchor: true, currentTaskOnly: true);
      final sql = await db.database;
      var items = await sql.query('customer_media_items',
          where: 'customer=?', whereArgs: ['buyer']);
      expect(items, hasLength(1));
      expect(items.single['item_id'], receipt);
      expect(
          (jsonDecode(items.single['media_json']! as String) as List)
              .single['path'],
          clear.media.single.path,
          reason: 'Inventory must follow the accepted new primary.');
      expect(await inventory.analysisReadyMessageIds('buyer'),
          isNot(contains(id)));
      expect(await db.generationDue('buyer'), isTrue,
          reason:
              'Only the image waits for its original; the caption remains eligible.');
      final upgraded = ((await store.read('buyer'))!['messages'] as List)
          .cast<Map>()
          .singleWhere((m) => m['id'] == id);
      expect(
          upgraded['service_evidence_revision']! as int, greaterThan(revision));

      final original = await image(clearBytes, clearQuality, original: true);
      expect(original.media.single.path, clear.media.single.path,
          reason: 'The same bytes can gain stronger original provenance.');
      expect(await store.promoteMedia('buyer', id, original), isTrue);
      final third = capture([original], 2);
      await db.saveCapture(third, activeIncomingIds: {id});
      await inventory.persist(third,
          verifiedAnchor: true, currentTaskOnly: true);
      expect(await inventory.analysisReadyMessageIds('buyer'),
          containsAll([receipt, id]));
      expect(await db.generationDue('buyer'), isTrue);
      expect(await db.unansweredWorkCounts(), {'buyer': 2});
      final incoming = ((await store.read('buyer'))!['messages'] as List)
          .cast<Map>()
          .where((m) => m['direction'] == 'incoming');
      expect(incoming.map((m) => m['id']), unorderedEquals([captionId, id]));
      expect(await db.isMessageFormallyAnswered('buyer', id), isFalse);
      expect(await db.isMessageFormallyAnswered('buyer', captionId), isFalse);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
