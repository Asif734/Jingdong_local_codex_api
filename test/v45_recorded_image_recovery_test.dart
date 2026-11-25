import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/unknown_message_clarifier.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';

const _folder = 'test/fixtures/v45_recorded_image_admission';
const _customer = 'jd_41aeec7741d05';
typedef _Frame = ({OcrInspection inspection, ViewportEvidence evidence});

Future<_Frame> _frame(String name) async {
  final manifest =
      jsonDecode(await File('$_folder/provenance.json').readAsString()) as Map;
  final expected = manifest['frames'][name] as Map;
  final png = await File('$_folder/$name.png').readAsBytes();
  final ocr = await File('$_folder/$name.ocr.json').readAsBytes();
  final capture = await File('$_folder/$name.capture.json').readAsBytes();
  expect(sha256.convert(png).toString(), expected['pngSHA256']);
  expect(sha256.convert(ocr).toString(), expected['ocrSHA256']);
  expect(sha256.convert(capture).toString(), expected['captureSHA256']);
  return (
    inspection: OcrInspection.fromMap({
      ...Map<String, Object?>.from(jsonDecode(utf8.decode(ocr)) as Map),
      'pngBase64': base64Encode(png),
    }),
    evidence: ViewportEvidence(
        Map<String, Object?>.from(jsonDecode(utf8.decode(capture)) as Map)),
  );
}

List<OcrVisualRegion> _cards(_Frame frame) {
  const selector = OcrImageCandidateSelector();
  final extraction = const OcrCaptureExtractor().analyze(frame.inspection);
  final text = extraction.capture?.messages
          .where((message) => message.direction == 'incoming')
          .map((message) => message.body) ??
      const <String>[];
  final cards = selector.select(frame.inspection, _customer,
      includeTextDense: true,
      allowUnlabeledLatestImage: true,
      customerText: text);
  return selector.recoverCustomerBlocks(frame.inspection, _customer,
      owned: cards,
      hasPinnedImage: frame.evidence.pinnedMedia?['kind'] == 'image');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real first photo is recovered despite diagonal OCR watermark noise',
      () async {
    final frame = await _frame('first');
    expect(frame.evidence.metadata['unreadArrivalKey'], isNotNull);
    expect(
        frame.inspection.observations.any((line) =>
            line.isWatermark &&
            line.confidence < .45 &&
            line.rotationDegrees.abs() > 10),
        isTrue);
    final cards = _cards(frame);
    expect(cards, hasLength(1));
    expect(
        const OcrCaptureExtractor()
            .mediaClockForRegion(frame.inspection, cards.single)
            .sentAt,
        DateTime.utc(2026, 11, 9, 9, 7, 57));
  });

  test('real loaded photo survives a later separate customer text bubble',
      () async {
    final frame = await _frame('second-loaded');
    expect(
        const OcrCaptureExtractor()
            .analyze(frame.inspection)
            .latestIncomingHasText,
        isTrue);
    final cards = _cards(frame);
    expect(cards, hasLength(1));
    final clock = const OcrCaptureExtractor()
        .mediaClockForRegion(frame.inspection, cards.single);
    expect(clock.sentAt, DateTime.utc(2026, 11, 9, 9, 9, 49));
    final nextHeader = frame.inspection.observations
        .singleWhere((line) => line.text == 'jd_41aeec7741d05 17:09:53');
    expect(cards.single.y + cards.single.height, lessThan(nextHeader.y));
  });

  test('real blank loading image already has one bounded physical proposal',
      () async {
    final loading = await _frame('second-loading');
    final loaded = await _frame('second-loaded');
    final waiting = _cards(loading).single;
    final ready = _cards(loaded).single;
    const extractor = OcrCaptureExtractor();
    expect(extractor.mediaClockForRegion(loading.inspection, waiting).sentAt,
        DateTime.utc(2026, 11, 9, 9, 9, 49));
    expect(extractor.mediaClockForRegion(loaded.inspection, ready).sentAt,
        DateTime.utc(2026, 11, 9, 9, 9, 49));
    expect(waiting.width, greaterThan(.30));
    expect((waiting.x - ready.x).abs(), lessThan(.003));
    expect(waiting.x + waiting.width,
        lessThanOrEqualTo(loading.inspection.chatRight!));
  });

  test('recovery preserves real short text and existing full video candidates',
      () async {
    final frame = await _frame('first');
    final cards = _cards(frame);
    expect(cards, hasLength(1),
        reason: 'The separate ok. block must never become an image.');
    expect(cards.single.y, greaterThan(.52));
    const folder = 'test/fixtures/v44_loading_media_owner';
    final raw =
        jsonDecode(await File('$folder/loaded.ocr.json').readAsString()) as Map;
    final video = OcrInspection.fromMap({
      ...Map<String, Object?>.from(raw),
      'pngBase64': base64Encode(await File('$folder/loaded.png').readAsBytes()),
    });
    const selector = OcrImageCandidateSelector();
    final native = selector.select(video, _customer, includeTextDense: true);
    expect(native, hasLength(1));
    final recovered =
        selector.recoverCustomerBlocks(video, _customer, owned: native);
    expect(recovered, native,
        reason: 'Video acquisition must retain its exact selected ROI.');
  });

  test('low confidence horizontal customer prose is not replaced by media',
      () async {
    final raw = jsonDecode(
        await File('$_folder/second-loading.ocr.json').readAsString()) as Map;
    final original = (raw['observations'] as List).whereType<Map>().toList();
    final view = OcrInspection.fromMap({
      ...Map<String, Object?>.from(raw),
      'visualRegions': const [],
      'unboundMediaRegions': const [],
      'observations': [
        ...original,
        {
          'text': 'The printer does not work',
          'confidence': .3,
          'x': .28,
          'y': .57,
          'width': .20,
          'height': .02,
          'rotationDegrees': 0,
          'isWatermark': false,
        }
      ]
    });
    expect(
        const OcrImageCandidateSelector()
            .recoverCustomerBlocks(view, _customer),
        isEmpty,
        reason:
            'Noise filtering must not blindly discard low-confidence text.');
  });

  test(
      'a sender-looking line printed inside an owned image is not a new bubble',
      () async {
    final raw =
        jsonDecode(await File('$_folder/second-loaded.ocr.json').readAsString())
            as Map;
    const card = OcrVisualRegion(
        x: .273, y: .44, width: .13, height: .19, confidence: 1);
    final view = OcrInspection.fromMap({
      ...Map<String, Object?>.from(raw),
      'observations': [
        ...(raw['observations'] as List),
        {
          'text': '$_customer 17:09:50',
          'confidence': 1.0,
          'x': .275,
          'y': .50,
          'width': .12,
          'height': .02,
          'rotationDegrees': 0,
          'isWatermark': false,
        }
      ]
    });
    expect(
        const OcrImageCandidateSelector()
            .recoverCustomerBlocks(view, _customer, owned: [card]),
        [card],
        reason: 'Media contents cannot manufacture a second incoming message.');
  });

  test(
      'recorded clipped tutorial preserves its legacy unknown-to-text identity',
      () async {
    const folder = 'test/fixtures/v39_message_correction';
    const selector = OcrImageCandidateSelector();
    for (final name in ['clipped-text', 'early-full-text', 'full-text']) {
      final raw =
          jsonDecode(await File('$folder/$name.ocr.json').readAsString())
              as Map;
      final view = OcrInspection.fromMap({
        ...Map<String, Object?>.from(raw),
        'pngBase64':
            base64Encode(await File('$folder/$name.png').readAsBytes()),
      });
      final owned = selector.select(view, _customer, includeTextDense: true);
      expect(selector.recoverCustomerBlocks(view, _customer, owned: owned),
          isEmpty,
          reason: '$name is text with no positive attachment evidence.');
      if (name == 'clipped-text') {
        final legacy = selector.fallbackLatestCustomerBlock(view, _customer);
        expect(legacy, isNotNull,
            reason: 'Keep the pre-existing unresolved-message placeholder.');
        expect(legacy!.x, view.chatLeft,
            reason:
                'Its original geometry is part of the clarification proof.');
        final complete = OcrInspection.fromMap(Map<String, Object?>.from(
            jsonDecode(await File('$folder/early-full-text.ocr.json')
                .readAsString()) as Map));
        final clarified = UnknownMessageClarifier.match(
            customer: _customer,
            original: view,
            originalRegion: legacy,
            current: complete,
            messages: const OcrCaptureExtractor().extract(complete)!.messages);
        expect(clarified?.body, 'can you share me a video?',
            reason:
                'The existing placeholder must become this same text message.');
      }
    }
  });

  test('one frozen image pin cannot attribute several empty incoming blocks',
      () async {
    final frame = await _frame('first');
    final raw =
        jsonDecode(await File('$_folder/first.ocr.json').readAsString()) as Map;
    final view = OcrInspection.fromMap({
      ...Map<String, Object?>.from(raw),
      'visualRegions': const [],
      'unboundMediaRegions': const [],
      'observations': [
        for (final line in (raw['observations'] as List).whereType<Map>())
          if (line['text'].toString().startsWith(_customer))
            {
              ...line,
              'y': line['text'].toString().contains('17:07:47') ? .30 : .50,
            },
      ]
    });
    expect(frame.evidence.pinnedMedia?['kind'], 'image');
    expect(
        const OcrImageCandidateSelector()
            .recoverCustomerBlocks(view, _customer, hasPinnedImage: true),
        isEmpty,
        reason: 'A pin alone cannot choose between separate empty bubbles.');
  });

  test('a frozen pin does not attach an earlier empty block above later text',
      () async {
    final raw =
        jsonDecode(await File('$_folder/second-loaded.ocr.json').readAsString())
            as Map;
    final view = OcrInspection.fromMap({
      ...Map<String, Object?>.from(raw),
      'visualRegions': const [],
      'unboundMediaRegions': const [],
    });
    expect(
        const OcrImageCandidateSelector()
            .recoverCustomerBlocks(view, _customer, hasPinnedImage: true),
        isEmpty,
        reason:
            'The earlier empty block needs its own fragment/ancestry proof.');
  });

  test(
      'real two same-file sends register pending before load and each survives late callbacks and formal coverage',
      () async {
    final root =
        await Directory.systemTemp.createTemp('jd_v45_recorded_image_');
    final db = CaptureDatabase(storageRoot: root);
    const channel = MethodChannel('v45-recorded-image-native');
    final sends = <String>[];
    try {
      await db.beginAutomationSession(
          startedAt: DateTime.utc(2026, 11, 9, 8, 47));
      final inventory = CustomerMediaInventory(db);
      final audit = MediaCaptureAudit(db, record: (_, __) {});
      final registrar =
          MediaMessageRegistrar(db, inventory: inventory, audit: audit);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        if (call.method == 'openConversation') {
          expect(args['expectedCustomer'], _customer);
          return {'opened': true, 'customer': _customer};
        }
        if (call.method == 'sendDraftOnce') {
          expect(args['expectedCustomer'], _customer);
          sends.add(args['reply'] as String);
          final at = DateTime.now().millisecondsSinceEpoch;
          await File(args['receiptPath'] as String).writeAsString(jsonEncode({
            'attemptId': args['attemptId'],
            'customer': _customer,
            'state': 'submitted',
            'sendClickedAtMs': at,
            'timeMs': at,
          }));
          return {
            'sent': true,
            'customer': _customer,
            'activeCustomerId': _customer,
            'sendClickedAtMs': at,
          };
        }
        throw StateError('Unexpected native operation: ${call.method}');
      });
      var sequence = 0;
      Future<({MediaMessageRegistration registration, _Frame frame})> observe(
          String name,
          {String suffix = ''}) async {
        final recorded = await _frame(name);
        final id = '${recorded.evidence.id}$suffix';
        final metadata = {
          ...recorded.evidence.metadata,
          'automationSessionId': db.currentAutomationSessionId,
          'evidenceId': id,
          'imagePath': File('$_folder/$name.png').absolute.path,
          'manifestPath': '${root.path}/$id.json',
        };
        if (metadata['pinnedMedia'] case final Map pin) {
          metadata['pinnedMedia'] = {
            ...pin,
            'evidenceFile': File('$_folder/$name.original').absolute.path,
          };
        }
        final frame = (
          evidence: ViewportEvidence(metadata),
          inspection: recorded.inspection
        );
        await File(frame.evidence.manifestPath)
            .writeAsString(frame.evidence.toJson());
        final registration = await registrar.register(
            evidence: frame.evidence,
            inspection: frame.inspection,
            cards: _cards(frame),
            visibleText: const OcrCaptureExtractor()
                    .extract(frame.inspection)
                    ?.messages ??
                const [],
            frontier: frame.evidence.metadata['admissionFrontier'] as Map?,
            registerOnly: true,
            nextMessageId: () => 'v45-image:${++sequence}');
        return (registration: registration, frame: frame);
      }

      Future<({MediaParent parent, _Frame frame})> receive(String name,
          {String suffix = ''}) async {
        final observed = await observe(name, suffix: suffix);
        expect(observed.registration.parents, hasLength(1),
            reason: '$name must have its actual bubble owner.');
        return (
          parent: observed.registration.parents.values.single,
          frame: observed.frame
        );
      }

      Future<List<Map<String, Object?>>> work() async =>
          (await db.database).query('automation_session_messages',
              where: 'session_id=? AND user_id=?',
              whereArgs: [db.currentAutomationSessionId, _customer]);
      final first = await receive('first');
      final loading = await observe('second-loading');
      expect(loading.registration.parents, isEmpty,
          reason:
              'No frozen AX arrival yet: a late clock alone cannot admit a card.');
      expect(loading.registration.observationIds, hasLength(1));
      expect(await work(), hasLength(1));
      final loaded = await receive('second-loaded');
      final second = (
        parent: loaded.parent,
        frame: loading.frame,
      );
      expect(first.parent.messageId, isNot(second.parent.messageId));
      expect(first.parent.receiptId, isNot(second.parent.receiptId));
      expect(await work(), hasLength(2));
      expect((await work()).map((r) => r['response_state']),
          everyElement('pending'));
      expect(await inventory.analysisReadyMessageIds(_customer), isEmpty,
          reason:
              'White loading is pending business, never formal completion.');
      expect((await receive('first-late')).parent.messageId,
          first.parent.messageId);
      expect((await receive('second-loaded')).parent.messageId,
          second.parent.messageId);
      expect((await receive('second-loading')).parent.messageId,
          second.parent.messageId);

      final savedPaths = <String>{};
      for (final item in [first, second]) {
        final pin = item.frame.evidence.metadata['pinnedMedia'] as Map;
        final bytes = await File(pin['evidenceFile'] as String).readAsBytes();
        final manifest =
            jsonDecode(await File('$_folder/provenance.json').readAsString())
                as Map;
        final name = item.parent.messageId == first.parent.messageId
            ? 'first'
            : 'second-loading';
        expect(sha256.convert(bytes).toString(),
            manifest['frames'][name]['originalSHA256']);
        final path = await (await db.history).saveMedia(
            userId: _customer,
            filename: 'actual-shared-image.jpeg',
            bytes: bytes);
        savedPaths.add(path);
        await inventory.classify(item.parent.receiptId, 'image');
        final capture = CapturedConversation(
            stableKey: _customer,
            customerName: _customer,
            customerExternalId: _customer,
            automationSessionId: db.currentAutomationSessionId,
            capturedAt: item.frame.evidence.capturedAt,
            messages: [
              CapturedMessage(
                  stableId: item.parent.messageId,
                  direction: 'incoming',
                  sender: _customer,
                  body:
                      '[Customer sent an image; original copied from JD cache]',
                  axPath: 'recorded-verified-jd-image-cache',
                  sentAt: const OcrCaptureExtractor()
                      .mediaClockForRegion(
                          item.frame.inspection, _cards(item.frame).single)
                      .sentAt,
                  mediaReceiptId: item.parent.receiptId,
                  captureEvidenceId: item.frame.evidence.id,
                  media: [
                    CapturedMedia(
                        type: 'image',
                        path: path,
                        captureSource: 'jd_image_cache',
                        mimeType: 'image/jpeg')
                  ])
            ]);
        await db.saveCapture(capture);
        await inventory.persist(capture,
            verifiedAnchor: true, currentTaskOnly: true);
        await audit.resolveCaptured(capture);
      }
      expect(savedPaths, hasLength(1),
          reason:
              'Assets may be reused while separate sends retain two owners.');
      expect(await inventory.analysisReadyMessageIds(_customer),
          containsAll([first.parent.messageId, second.parent.messageId]));
      final pending = (await db.conversation(_customer))!;
      final token = (await db.beginGeneration(
          customer: _customer,
          pendingId: pending.id,
          batchEndMessageId: second.parent.messageId))!;
      expect(
          await db.generationInputsAnalysisReady(_customer,
              generationToken: token),
          isTrue);
      final input = (await db.generationMessages(_customer,
              batchEndMessageId: second.parent.messageId))
          .where((message) => message['direction'] == 'incoming');
      expect(input.map((message) => message['id']).toSet(),
          {first.parent.messageId, second.parent.messageId});
      await (await db.history).updateMediaDescriptions(_customer, {
        savedPaths.single:
            'The image shows the Grozziie app home page and its Add Other Device button.'
      });
      final draft = await db.prepareAutomaticDraft(
          _customer,
          AiDraft.fromJson({
            'reply':
                'I received both screenshots. Tap Add Other Device to connect your printer.',
            'reply_purpose': 'substantive',
            'decision': 'draft',
            'confidence': 1,
            'risk_level': 'low',
            'model': 'controlled-v45-image-analysis',
          }, mediaBaseUrl: Uri()));
      expect(
          await db.saveDraft(pending.id, draft,
              expectedMessageId: second.parent.messageId,
              expectedUserId: _customer,
              generationToken: token),
          1);
      await db.abandonGeneration(_customer, token);
      final attempt =
          await db.beginDeliveryAttempt(userId: _customer, reply: draft.reply);
      final adapter = MacOSCaptureAdapter(channel: channel);
      await adapter.openConversation(_customer, allowActivation: true);
      expect(
          (await adapter.sendDraftOnce(
              expectedCustomer: _customer,
              reply: draft.reply,
              attemptId: attempt['attemptId'],
              receiptPath: attempt['receiptPath']))['sent'],
          isTrue);
      await db.recoverDeliveryReceipts();
      final answered = await work();
      expect(answered, hasLength(2));
      expect(answered.map((row) => row['response_state']),
          everyElement('answered'));
      expect(answered.map((row) => row['answered_attempt_id']).toSet(),
          {attempt['attemptId']});
      for (final name in [
        'second-loaded',
        'first',
        'first-late',
        'second-loading'
      ]) {
        final old = await receive(name, suffix: '-after-formal');
        expect(
            old.parent.messageId,
            name.startsWith('first')
                ? first.parent.messageId
                : second.parent.messageId);
      }
      expect(await work(), hasLength(2));
      expect(await db.hasPendingUnanswered(_customer), isFalse);
      expect(sends, hasLength(1));
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
