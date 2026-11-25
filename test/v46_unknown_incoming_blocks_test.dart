import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/incoming_message_blocks.dart';
import 'package:jd_automation/capture/live_media_admission.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/unknown_message_clarifier.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';

import 'helpers/media_admission_fixture.dart';

const _folder = 'test/fixtures/v46_unknown_incoming';
const _customer = 'jd_5f2331ef08167';
final _start = DateTime.utc(2026, 11, 10, 2, 13, 36);
typedef _Frame = ({
  ViewportEvidence evidence,
  OcrInspection view,
  Map<String, Object?> raw
});

Future<_Frame> _frame(String name,
    {String session = 'component-session'}) async {
  final provenance =
      jsonDecode(await File('$_folder/provenance.json').readAsString()) as Map;
  final frame = provenance['frames'][name] as Map;
  final image = await File('$_folder/$name.png').readAsBytes();
  final ocr = await File('$_folder/$name.ocr.json').readAsBytes();
  final capture = await File('$_folder/$name.capture.json').readAsBytes();
  expect(sha256.convert(image).toString(), frame['pngSHA256']);
  expect(sha256.convert(ocr).toString(), frame['ocr.jsonSHA256']);
  expect(sha256.convert(capture).toString(), frame['capture.jsonSHA256']);
  final raw = Map<String, Object?>.from(jsonDecode(utf8.decode(ocr)) as Map);
  final evidence = ViewportEvidence({
    ...Map<String, Object?>.from(jsonDecode(utf8.decode(capture)) as Map),
    'automationSessionId': session,
    'imagePath': File('$_folder/$name.png').absolute.path,
  });
  return (
    evidence: evidence,
    raw: raw,
    view: OcrInspection.fromMap({...raw, 'pngBase64': base64Encode(image)})
  );
}

List<OcrVisualRegion> _nativeIncomingCards(_Frame f) => f.view.visualRegions
    .where((r) =>
        r.x >= (f.view.chatLeft ?? .24) &&
        r.x < .4 &&
        r.height > .065 &&
        r.width > .025)
    .toList();

List<OcrIncomingMessageBlock> _unknown(_Frame f,
    {Map<OcrVisualRegion, String> knownParents = const {},
    Iterable<OcrVisualRegion>? media,
    DateTime? startedAt,
    String session = 'component-session'}) {
  final regions = media ?? _nativeIncomingCards(f);
  return UnknownIncomingBlocks.locate(
      evidence: f.evidence,
      inspection: f.view,
      messages: const OcrCaptureExtractor()
              .analyze(f.view, excludedMediaRegions: regions.toList())
              .capture
              ?.messages ??
          const [],
      mediaRegions: regions,
      knownMediaParents: knownParents,
      frontier: f.evidence.metadata['admissionFrontier'] as Map?,
      sessionId: session,
      sessionStartedAt: startedAt ?? _start);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'actual independent unread question survives an existing media candidate',
      () async {
    for (final name in ['0e40', 'd09', 'fdd']) {
      final f = await _frame(name);
      final cards = _nativeIncomingCards(f);
      expect(cards, isNotEmpty);
      final frontier = f.evidence.metadata['admissionFrontier'] as Map?;
      final known = name == '0e40' || name == 'fdd'
          ? {cards.first: frontier!['id']! as String}
          : <OcrVisualRegion, String>{};
      final unknown = _unknown(f, knownParents: known);
      expect(
          unknown
              .where((b) => b.sentAt == DateTime.utc(2026, 11, 10, 2, 26, 53)),
          hasLength(1),
          reason: '$name must retain the independent question block.');
      final block = unknown.firstWhere((b) => b.sentAt.minute == 26);
      expect(
          block.textRecoveryRegions
              .every((r) => r.width <= .2 && r.height <= .1),
          isTrue);
    }
  });

  test(
      'before-frontier recovery requires a real current parent and no history divider',
      () async {
    final f = await _frame('fdd');
    final cards = _nativeIncomingCards(f);
    final frontier = f.evidence.metadata['admissionFrontier'] as Map;
    final parents = {cards.first: frontier['id']! as String};
    bool includesQuestion(Iterable<OcrIncomingMessageBlock> blocks) =>
        blocks.any((b) => b.sentAt == DateTime.utc(2026, 11, 10, 2, 26, 53));
    expect(includesQuestion(_unknown(f)), isFalse);
    expect(includesQuestion(_unknown(f, knownParents: parents)), isTrue);
    final historical = (
      evidence: ViewportEvidence({
        ...f.evidence.metadata,
        'historyCutoffMs': f.evidence.capturedAt.millisecondsSinceEpoch,
        'capturePurpose': 'history_backfill',
      }),
      view: f.view,
      raw: f.raw
    );
    expect(
        includesQuestion(_unknown(historical, knownParents: parents)), isFalse);
    final dividedRaw = <String, Object?>{
      ...f.raw,
      'observations': [
        ...(f.raw['observations'] as List),
        {
          'text': '以下为新消息',
          'confidence': 1.0,
          'x': .4,
          'y': .46,
          'width': .1,
          'height': .02,
        }
      ]
    };
    final divided = (
      evidence: f.evidence,
      view: OcrInspection.fromMap(dividedRaw),
      raw: dividedRaw
    );
    expect(includesQuestion(_unknown(divided, knownParents: parents)), isFalse);
  });

  test(
      'ordinary later seller greeting does not erase actual prior current image',
      () async {
    final f = await _frame('ae346');
    final cards = _nativeIncomingCards(f);
    final clocks = {
      for (final r in cards)
        r: const OcrCaptureExtractor().mediaClockForRegion(f.view, r)
    };
    final admitted = LiveMediaArrival.infer(
        evidence: f.evidence,
        inspection: f.view,
        cards: cards,
        headers: clocks,
        knownParents: const {},
        visibleText:
            const OcrCaptureExtractor().extract(f.view)?.messages ?? const [],
        sessionStartedAt: _start);
    expect(admitted, isNotEmpty);
    expect(
        admitted.keys.any(
            (r) => clocks[r]?.sentAt == DateTime.utc(2026, 11, 10, 2, 20, 41)),
        isTrue);
    final noMediaOwnerYet = _unknown(f, media: const []);
    expect(
        noMediaOwnerYet
            .any((b) => b.sentAt == DateTime.utc(2026, 11, 10, 2, 20, 41)),
        isTrue);
  });

  test('Start red-marked media retains original AX/frontier admission policy',
      () async {
    final f = await _frame('ae346');
    final cards = _nativeIncomingCards(f);
    final clocks = {
      for (final card in cards)
        card: const OcrCaptureExtractor().mediaClockForRegion(f.view, card)
    };
    final laterStart = DateTime.utc(2026, 11, 10, 2, 20, 50);
    // This media predates Start, so the new recovery above a later seller
    // greeting must not use its OCR clock as current-run proof.
    expect(
        LiveMediaArrival.infer(
            evidence: f.evidence,
            inspection: f.view,
            cards: cards,
            headers: clocks,
            knownParents: const {},
            visibleText: const [],
            sessionStartedAt: laterStart),
        isEmpty);
    final originalAXPath = OcrInspection.fromMap({
      ...f.raw,
      'observations': (f.raw['observations'] as List)
          .where(
              (line) => (line as Map)['text'].toString().startsWith(_customer))
          .toList(),
    });
    // A customer already marked unread at Start still follows the established
    // AX path when its block is after the last seller. No old DB task resumes.
    expect(
        LiveMediaArrival.infer(
            evidence: f.evidence,
            inspection: originalAXPath,
            cards: cards,
            headers: clocks,
            knownParents: const {},
            visibleText: const [],
            sessionStartedAt: laterStart),
        isNotEmpty);
  });

  test(
      'actual fdd gap reaches one owner only through a current physical anchor',
      () async {
    for (final scenario in ['current-parent', 'no-parent', 'history']) {
      final root = await Directory.systemTemp.createTemp('jd_v46_gap_');
      final db = CaptureDatabase(storageRoot: root);
      try {
        final session = await db.beginAutomationSession(startedAt: _start);
        final recorded = await _frame('fdd', session: session);
        final f = (
          evidence: scenario == 'history'
              ? ViewportEvidence({
                  ...recorded.evidence.metadata,
                  'historyCutoffMs':
                      recorded.evidence.capturedAt.millisecondsSinceEpoch,
                  'capturePurpose': 'history_backfill',
                })
              : recorded.evidence,
          view: recorded.view,
          raw: recorded.raw
        );
        final photo = _nativeIncomingCards(f).first;
        final frontier = f.evidence.metadata['admissionFrontier'] as Map;
        final inventory = CustomerMediaInventory(db);
        final audit = MediaCaptureAudit(db, record: (_, __) {});
        final registrar = MediaMessageRegistrar(db, audit: audit);
        if (scenario != 'no-parent') {
          final receipt = await inventory.observe(
              customer: _customer,
              evidenceId: f.evidence.id,
              observedAt: f.evidence.capturedAt,
              senderAt: DateTime.utc(2026, 11, 10, 2, 27, 22),
              slot: 0,
              region: [photo.x, photo.y, photo.width, photo.height],
              current: true);
          await admitFixtureMedia(db,
              customer: _customer,
              receiptId: receipt,
              messageId: frontier['id']! as String,
              receivedAt: f.evidence.capturedAt,
              senderAt: DateTime.utc(2026, 11, 10, 2, 27, 22));
          final observation = await audit.discover(f.evidence, photo,
              inspection: f.view, physicalCards: [photo]);
          await audit.bindParent(observation,
              receiptId: receipt, messageId: frontier['id']! as String);
        }
        final visible = const OcrCaptureExtractor()
                .analyze(f.view, excludedMediaRegions: [photo])
                .capture
                ?.messages ??
            const <CapturedMessage>[];
        final first = await registrar.register(
            evidence: f.evidence,
            inspection: f.view,
            cards: [photo],
            visibleText: visible,
            frontier: frontier,
            registerOnly: true);
        final proposal = const OcrCaptureExtractor()
            .incomingMessageBlocks(f.view, excludedMediaRegions: [
          photo
        ]).singleWhere(
                (b) => b.sentAt == DateTime.utc(2026, 11, 10, 2, 26, 53));
        final located = _unknown(f, session: session, knownParents: {
          for (final entry in first.parents.entries)
            entry.key: entry.value.messageId
        });
        expect(located.any((b) => b.sentAt == proposal.sentAt),
            scenario == 'current-parent',
            reason: scenario);
        // Even a stale caller proposal cannot bypass the registrar's guarded
        // revalidation. There is no decode/crop operation on this duty.
        final second = await registrar.register(
            evidence: f.evidence,
            inspection: f.view,
            cards: [photo, proposal.region],
            unknownBodyRegions: [proposal.region],
            visibleText: visible,
            frontier: frontier,
            registerOnly: true);
        expect(second.parents.containsKey(proposal.region),
            scenario == 'current-parent',
            reason: scenario);
        expect(second.createdAdmissions.length,
            scenario == 'current-parent' ? 1 : 0,
            reason: scenario);
        if (scenario == 'current-parent') {
          final parent = second.parents[proposal.region]!;
          expect(await inventory.analysisReadyMessageIds(_customer),
              isNot(contains(parent.messageId)));
          final repeated = await registrar.register(
              evidence: f.evidence,
              inspection: f.view,
              cards: [photo, proposal.region],
              unknownBodyRegions: [proposal.region],
              visibleText: visible,
              frontier: frontier,
              registerOnly: true);
          expect(
              repeated.parents[proposal.region]?.messageId, parent.messageId);
          expect(repeated.createdAdmissions, isEmpty);
        }
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    }
  });

  test(
      'customer punctuation is retained while photo-internal sender text is masked',
      () async {
    final f = await _frame('0e40');
    for (final punctuation in ['?', '？', '.', '...']) {
      final raw = {
        ...f.raw,
        'visualRegions': <Object>[],
        'unboundMediaRegions': <Object>[],
        'observations': [
          {
            'text': '$_customer 10:26:53',
            'confidence': 1.0,
            'x': .27,
            'y': .3,
            'width': .18,
            'height': .02
          },
          {
            'text': punctuation,
            'confidence': 1.0,
            'x': .28,
            'y': .35,
            'width': .02,
            'height': .02
          },
        ]
      };
      final view = OcrInspection.fromMap(raw);
      expect(const OcrCaptureExtractor().extract(view)!.messages.single.body,
          punctuation);
    }
    final card = _nativeIncomingCards(f).first;
    final photoText = OcrInspection.fromMap({
      ...f.raw,
      'observations': [
        ...(f.raw['observations'] as List),
        {
          'text': '$_customer 10:26:00',
          'confidence': 1.0,
          'x': card.x + .005,
          'y': card.y + .04,
          'width': .06,
          'height': .018,
        }
      ]
    });
    final blocks = const OcrCaptureExtractor()
        .incomingMessageBlocks(photoText, excludedMediaRegions: [card]);
    expect(
        blocks.any(
            (block) => block.sentAt.minute == 26 && block.sentAt.second == 0),
        isFalse);
  });

  test('unknown admission never comes from another session or passive history',
      () async {
    final f = await _frame('d09');
    expect(_unknown(f, session: 'different-session'), isEmpty);
    expect(_unknown(f, startedAt: DateTime.utc(2026, 11, 10, 2, 28)), isEmpty);
    final passive = (
      evidence: ViewportEvidence(
          {...f.evidence.metadata, 'replyActivationAllowed': false}),
      view: f.view,
      raw: f.raw
    );
    expect(_unknown(passive), isEmpty);
    final noProof = (
      evidence: ViewportEvidence({
        ...f.evidence.metadata,
        'unreadArrivalKey': null,
        'admissionFrontier': null
      }),
      view: f.view,
      raw: f.raw
    );
    expect(_unknown(noProof), isEmpty);
  });

  test(
      'actual tight native decode changes the same unknown owner before formal delivery',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v46_unknown_');
    final db = CaptureDatabase(storageRoot: root);
    const channel = MethodChannel('v46-unknown-formal-native');
    var sends = 0;
    try {
      final session = await db.beginAutomationSession(startedAt: _start);
      final f = await _frame('0e40', session: session);
      final cards = _nativeIncomingCards(f);
      final frontier = f.evidence.metadata['admissionFrontier'] as Map;
      final inventory = CustomerMediaInventory(db);
      final audit = MediaCaptureAudit(db, record: (_, __) {});
      final photo = cards.first;
      final oldReceipt = await inventory.observe(
          customer: _customer,
          evidenceId: f.evidence.id,
          observedAt: f.evidence.capturedAt,
          senderAt: DateTime.utc(2026, 11, 10, 2, 25, 16),
          slot: 0,
          region: [photo.x, photo.y, photo.width, photo.height],
          current: true);
      await admitFixtureMedia(db,
          customer: _customer,
          receiptId: oldReceipt,
          messageId: frontier['id']! as String,
          receivedAt: f.evidence.capturedAt,
          senderAt: DateTime.utc(2026, 11, 10, 2, 25, 16));
      final photoObservation = await audit.discover(f.evidence, photo,
          inspection: f.view, physicalCards: [photo]);
      await audit.bindParent(photoObservation,
          receiptId: oldReceipt, messageId: frontier['id']! as String);
      final blocks = _unknown(f,
          session: session, knownParents: {photo: frontier['id']! as String});
      final block = blocks.singleWhere((b) => b.sentAt.minute == 26);
      final registered = await MediaMessageRegistrar(db, audit: audit).register(
          evidence: f.evidence,
          inspection: f.view,
          cards: [photo, block.region],
          unknownBodyRegions: [block.region],
          visibleText: const OcrCaptureExtractor()
                  .analyze(f.view, excludedMediaRegions: cards)
                  .capture
                  ?.messages ??
              const [],
          frontier: frontier,
          registerOnly: true);
      final parent = registered.parents[block.region]!;
      expect(await inventory.analysisReadyMessageIds(_customer),
          isNot(contains(parent.messageId)));
      final provenance =
          jsonDecode(await File('$_folder/provenance.json').readAsString())
              as Map;
      final nativeBytes =
          await File('$_folder/0e40.native-repeat.json').readAsBytes();
      expect(sha256.convert(nativeBytes).toString(),
          provenance['nativeRepeat']['sha256']);
      final attempts =
          (jsonDecode(utf8.decode(nativeBytes)) as List).cast<List>();
      expect(attempts, hasLength(3));
      for (final actual in attempts) {
        expect(actual.single['text'], '？');
        expect(actual.single['confidence'], .5);
      }
      final native = attempts.first.cast<Map>();
      final roi = block.textRecoveryRegions.first;
      final crop = provenance['nativeRepeat']['crop'] as Map;
      expect([roi.x, roi.y, roi.width, roi.height],
          [crop['x'], crop['y'], crop['width'], crop['height']]);
      expect(native.single['text'], '？');
      final refined = OcrInspection.fromMap({
        ...f.raw,
        'pngBase64': base64Encode(f.view.image),
        'observations': [...(f.raw['observations'] as List), ...native]
      });
      final text = UnknownMessageClarifier.match(
          customer: _customer,
          original: f.view,
          originalRegion: block.region,
          current: refined,
          messages: const OcrCaptureExtractor()
              .analyze(refined, excludedMediaRegions: cards)
              .capture!
              .messages,
          excludedRegions: cards);
      expect(text?.body, '？');
      final canonical = await db.clarifyUnknownMessageAsText(_customer,
          parentMessageId: parent.messageId,
          receiptId: parent.receiptId,
          text: text!,
          evidenceId: f.evidence.id,
          expectedSessionId: session);
      expect(canonical, parent.messageId);
      final pending = (await db.conversation(_customer))!;
      final token = (await db.beginGeneration(
          customer: _customer,
          pendingId: pending.id,
          batchEndMessageId: parent.messageId))!;
      final input = await db.generationMessages(_customer,
          batchEndMessageId: parent.messageId);
      expect(
          input.where((m) => m['direction'] == 'incoming').map((m) => m['id']),
          [parent.messageId]);
      final draft = await db.prepareAutomaticDraft(
          _customer,
          AiDraft.fromJson({
            'reply': '请问现在电脑上显示什么提示？',
            'reply_purpose': 'substantive',
            'decision': 'draft',
            'confidence': 1,
            'risk_level': 'low',
            'model': 'v46-controlled-question-answer'
          }, mediaBaseUrl: Uri()));
      expect(
          await db.saveDraft(pending.id, draft,
              expectedUserId: _customer,
              expectedMessageId: parent.messageId,
              generationToken: token),
          1);
      await db.abandonGeneration(_customer, token);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = call.arguments as Map;
        if (call.method == 'openConversation') {
          return {'opened': true, 'customer': _customer};
        }
        expect(call.method, 'sendDraftOnce');
        sends++;
        final at = DateTime.now().millisecondsSinceEpoch;
        await File(args['receiptPath']! as String).writeAsString(jsonEncode({
          'customer': _customer,
          'attemptId': args['attemptId'],
          'state': 'submitted',
          'timeMs': at,
          'sendClickedAtMs': at
        }));
        return {
          'sent': true,
          'customer': _customer,
          'activeCustomerId': _customer,
          'sendClickedAtMs': at
        };
      });
      final attempt =
          await db.beginDeliveryAttempt(userId: _customer, reply: draft.reply);
      final adapter = MacOSCaptureAdapter(channel: channel);
      await adapter.openConversation(_customer, allowActivation: true);
      await adapter.sendDraftOnce(
          expectedCustomer: _customer,
          reply: draft.reply,
          attemptId: attempt['attemptId'],
          receiptPath: attempt['receiptPath']);
      await db.recoverDeliveryReceipts();
      expect(sends, 1);
      expect(await db.isMessageFormallyAnswered(_customer, parent.messageId),
          isTrue);
      expect(
          await db.isMessageFormallyAnswered(
              _customer, frontier['id']! as String),
          isFalse,
          reason:
              'An unrelated pending image is never completed by answering the question.');
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
