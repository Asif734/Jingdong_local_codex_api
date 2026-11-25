import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/red_clock_tracker.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';

import 'helpers/completed_video_fixture.dart';
import 'helpers/run_permissions.dart';

const _customer = 'jd_41aeec7741d05';
const _fixtures = 'test/fixtures/v42_recorded_video_identity';
const _channel = MethodChannel('jd-v42-recorded-media-identity');

/// The PNG, native rectangle, OCR sender blocks and frozen admission metadata
/// are copied from the failing v41 run. Only the native send and already
/// completed media extraction are controlled. No decoder/cache/audio logic is
/// replaced in production by this test, and no real customer UI is contacted.
class _RecordedMediaFlow {
  _RecordedMediaFlow(this.root, this.db) {
    inventory = CustomerMediaInventory(db);
    audit = MediaCaptureAudit(db, record: (_, __) {});
    registrar = MediaMessageRegistrar(db, inventory: inventory, audit: audit);
  }

  final Directory root;
  final CaptureDatabase db;
  late final CustomerMediaInventory inventory;
  late final MediaCaptureAudit audit;
  late final MediaMessageRegistrar registrar;
  final adapter = MacOSCaptureAdapter(channel: _channel);
  final frames = <String, Map<String, dynamic>>{};
  final generatedInputs = <List<String>>[];
  final nativeSends = <String>[];
  var sequence = 0;

  Future<void> initialize() async {
    final manifest =
        jsonDecode(await File('$_fixtures/provenance.json').readAsString())
            as Map;
    frames.addAll((manifest['frames'] as Map).map(
        (key, value) => MapEntry('$key', Map<String, dynamic>.from(value))));
    await db.beginAutomationSession(
        startedAt: DateTime.utc(2026, 11, 9, 3, 39, 39));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      final args = Map<String, Object?>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'openConversation':
          expect(args['expectedCustomer'], _customer);
          return {'opened': true, 'customer': _customer};
        case 'sendDraftOnce':
          expect(args['expectedCustomer'], _customer);
          nativeSends.add(args['reply']! as String);
          final at = DateTime.now().millisecondsSinceEpoch;
          await File(args['receiptPath']! as String).writeAsString(jsonEncode({
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
      return <String, Object?>{};
    });
  }

  Future<
          ({
            ViewportEvidence evidence,
            OcrInspection inspection,
            OcrVisualRegion region
          })>
      recorded(String name,
          {String? suffix, Map<String, Object?> metadata = const {}}) async {
    final fixture = frames[name]!;
    final raw = Map<String, Object?>.from(
        jsonDecode(await File('$_fixtures/$name.ocr.json').readAsString())
            as Map);
    final png = await File('$_fixtures/$name.png').readAsBytes();
    expect(sha256.convert(png).toString(), fixture['pngSHA256']);
    expect(
        sha256
            .convert(await File('$_fixtures/$name.ocr.json').readAsBytes())
            .toString(),
        fixture['ocrSHA256']);
    final id = '${fixture['recordedEvidenceId']}${suffix ?? ''}';
    final evidence = ViewportEvidence({
      ...Map<String, Object?>.from(fixture['metadata'] as Map),
      'evidenceId': id,
      'imagePath': File('$_fixtures/$name.png').absolute.path,
      'manifestPath': '${root.path}/$id.json',
      'automationSessionId': db.currentAutomationSessionId,
      ...metadata,
    });
    await File(evidence.manifestPath).writeAsString(evidence.toJson());
    final inspection = OcrInspection.fromMap({
      ...raw,
      'capturedAtMs': evidence.metadata['capturedAtMs'],
      'pngBase64': base64Encode(png),
    });
    final box = (fixture['region'] as List).cast<num>();
    return (
      evidence: evidence,
      inspection: inspection,
      region: OcrVisualRegion(
          x: box[0].toDouble(),
          y: box[1].toDouble(),
          width: box[2].toDouble(),
          height: box[3].toDouble(),
          confidence: 1)
    );
  }

  Future<MediaParent?> replay(String name,
      {String? suffix, Map<String, Object?> metadata = const {}}) async {
    final frame = await recorded(name, suffix: suffix, metadata: metadata);
    return register(frame.evidence, frame.inspection, frame.region);
  }

  Future<MediaParent?> register(ViewportEvidence evidence,
      OcrInspection inspection, OcrVisualRegion region) async {
    final text = const OcrCaptureExtractor().extract(inspection);
    final result = await registrar.register(
      evidence: evidence,
      inspection: inspection,
      cards: [region],
      visibleText: text?.messages ?? const [],
      frontier: evidence.metadata['admissionFrontier'] as Map?,
      registerOnly: true,
      nextMessageId: () =>
          'incoming-media:${db.currentAutomationSessionId}:${++sequence}',
    );
    return result.parents[region];
  }

  Future<void> complete(MediaParent parent) async {
    // This is the unchanged decoder's terminal payload boundary. Identity
    // regression does not invoke or modify cache/download/frame/audio work.
    final assets = await completedVideoFixture(root, name: 'completed-video');
    await inventory.classify(parent.receiptId, 'video');
    final capture = CapturedConversation(
        stableKey: _customer,
        customerName: _customer,
        customerExternalId: _customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: DateTime.now().toUtc(),
        messages: [
          CapturedMessage(
            stableId: parent.messageId,
            direction: 'incoming',
            body: '[Customer sent a video]',
            sender: _customer,
            sentAt: DateTime.utc(2026, 11, 9, 3, 44),
            axPath: 'completed native video fixture',
            mediaReceiptId: parent.receiptId,
            media: assets,
          )
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture,
        verifiedAnchor: true, currentTaskOnly: true);
    expect(await inventory.analysisReadyMessageIds(_customer),
        contains(parent.messageId));
  }

  Future<void> formal(MediaParent parent) async {
    final customer = (await db.conversation(_customer))!;
    final token = await db.beginGeneration(
        customer: _customer,
        pendingId: customer.id,
        batchEndMessageId: parent.messageId);
    expect(token, isNotNull);
    expect(
        await db.generationInputsAnalysisReady(_customer,
            generationToken: token!),
        isTrue);
    final inputs = (await db.generationMessages(_customer,
            batchEndMessageId: parent.messageId))
        .where((m) => m['direction'] == 'incoming')
        .toList();
    generatedInputs.add(inputs.map((m) => m['id']! as String).toList());
    expect(inputs, hasLength(1));
    expect(inputs.single['id'], parent.messageId);
    final media = (inputs.single['media'] as List).cast<Map>();
    final draft = await db.prepareAutomaticDraft(
        _customer,
        AiDraft.fromJson({
          'reply': 'I checked the complete video. Please check the paper feed.',
          'reply_purpose': 'substantive',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-v42-recorded',
          'image_descriptions': [
            for (final item in media.where((m) => m['type'] == 'image'))
              {
                'path': item['path'],
                'description': 'Controlled complete frame analysis.'
              }
          ],
        }, mediaBaseUrl: Uri()));
    expect(
        await db.saveDraft(customer.id, draft,
            expectedMessageId: parent.messageId,
            expectedUserId: _customer,
            generationToken: token),
        1);
    await db.abandonGeneration(_customer, token);
    final attempt =
        await db.beginDeliveryAttempt(userId: _customer, reply: draft.reply);
    await adapter.openConversation(_customer, allowActivation: true);
    final confirmation = await adapter.sendDraftOnce(
        expectedCustomer: _customer,
        reply: draft.reply,
        attemptId: attempt['attemptId'],
        receiptPath: attempt['receiptPath']);
    expect(confirmation['sent'], isTrue);
    await db.recoverDeliveryReceipts();
    expect(await db.isMessageFormallyAnswered(_customer, parent.messageId),
        isTrue);
  }

  Future<List<Map<String, Object?>>> work() async =>
      (await db.database).query('automation_session_messages',
          where: 'session_id=? AND user_id=?',
          whereArgs: [db.currentAutomationSessionId, _customer]);
  Future<
      List<
          Map<String, Object?>>> owners() async => (await db.database).query(
      'customer_media_items',
      where:
          'customer=? AND admission_session_id=? AND message_id IS NOT NULL AND canonical_id IS NULL',
      whereArgs: [_customer, db.currentAutomationSessionId]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _homeTests();
  group('recorded media registrar', () {
    late Directory root;
    late CaptureDatabase db;
    late _RecordedMediaFlow flow;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('jd_v42_recorded_video_');
      db = CaptureDatabase(storageRoot: root);
      flow = _RecordedMediaFlow(root, db);
      await flow.initialize();
    });
    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      await db.close();
      await root.delete(recursive: true);
    });

    test(
        'recorded184 then f109 then f4 registers one video and one formal reply',
        () async {
      final first = (await flow.replay('gray-play'))!;
      final loaded = (await flow.replay('loaded'))!;
      final delayed = (await flow.replay('gray-clipped'))!;
      expect(loaded.receiptId, first.receiptId);
      expect(delayed.receiptId, first.receiptId);
      expect(
          [loaded.messageId, delayed.messageId], everyElement(first.messageId));
      expect(await flow.owners(), hasLength(1));
      expect(await flow.work(), hasLength(1));
      expect(await db.hasPendingUnanswered(_customer), isTrue);
      await flow.complete(first);
      await flow.formal(first);
      expect(flow.generatedInputs, [
        [first.messageId]
      ]);
      expect(flow.nativeSends, hasLength(1));
      expect((await flow.work()).single['response_state'], 'answered');
      expect(await db.hasPendingUnanswered(_customer), isFalse);
    });

    test(
        'overlapping recorded observations serialize before parent registration',
        () async {
      final results = await Future.wait([
        flow.replay('gray-play'),
        flow.replay('loaded'),
        flow.replay('gray-clipped'),
        flow.replay('loaded'),
      ]);
      expect(results, everyElement(isNotNull));
      expect(results.map((p) => p!.receiptId).toSet(), hasLength(1));
      expect(results.map((p) => p!.messageId).toSet(), hasLength(1));
      expect(await flow.owners(), hasLength(1));
      expect(await flow.work(), hasLength(1));
      await flow.complete(results.first!);
      await flow.formal(results.first!);
      expect(flow.generatedInputs, hasLength(1));
      expect(flow.nativeSends, hasLength(1));
    });

    test(
        'formal completion followed by old gray frame cannot reopen video work',
        () async {
      final first = (await flow.replay('gray-play'))!;
      expect((await flow.replay('loaded'))!.messageId, first.messageId);
      await flow.complete(first);
      await flow.formal(first);
      final before = await flow.work();
      final delayed = (await flow.replay('gray-clipped'))!;
      expect(delayed.messageId, first.messageId);
      expect(delayed.receiptId, first.receiptId);
      final repeated = (await flow.replay('gray-play'))!;
      expect(repeated.messageId, first.messageId);
      final headerless =
          await flow.replay('after-formal-headerless', metadata: {
        'admissionFrontier': {
          ...Map<String, Object?>.from(
              flow.frames['after-formal-headerless']!['metadata']
                  ['admissionFrontier'] as Map),
          'id': first.messageId,
        },
      });
      // A headerless old view can remain non-admitted if continuation is not
      // provable; it must never invent a second pending business message.
      if (headerless != null) expect(headerless.messageId, first.messageId);
      expect(await flow.work(), before);
      expect(await flow.owners(), hasLength(1));
      expect(await db.hasPendingUnanswered(_customer), isFalse);
      expect(await db.conversation(_customer), isNull,
          reason:
              'Successful formal completion removes the pending queue row.');
      expect(flow.nativeSends, hasLength(1));
    });

    test(
        'recorded loading observations retain their group before any parent exists',
        () async {
      final groups = <String>[];
      for (final name in ['gray-play', 'loaded', 'gray-clipped']) {
        final frame = await flow.recorded(name);
        final observation = await flow.audit.discoverUnbound(
            frame.evidence, frame.region,
            inspection: frame.inspection);
        final group = await flow.audit.groupUnbound(
            frame.evidence, frame.region, observation,
            inspection: frame.inspection);
        expect(group['videoOccurrenceProven'], isTrue);
        groups.add(group['observationGroupId']! as String);
        // Neither a screenshot nor a grouped preview is business admission.
        expect(await flow.work(), isEmpty);
      }
      expect(groups.toSet(), hasLength(1));
      final first = (await flow.replay('gray-play'))!;
      expect((await flow.replay('loaded'))!.messageId, first.messageId);
      expect((await flow.replay('gray-clipped'))!.messageId, first.messageId);
      expect(await flow.work(), hasLength(1));
    });

    test('two separate same-second cards retain independent business owners',
        () async {
      // Deliberately constructed adjacency guard: two cards are simultaneously
      // visible beneath two independent sender blocks with the same clock.
      // This supplements, rather than alters, the recorded one-card replay.
      final source =
          await flow.recorded('loaded', suffix: '-two-same-second', metadata: {
        'admissionFrontier': {'empty': true}
      });
      final raw = Map<String, Object?>.from(
          jsonDecode(await File('$_fixtures/loaded.ocr.json').readAsString())
              as Map);
      final inspection = OcrInspection.fromMap({
        ...raw,
        'observations': [
          for (final y in [.28, .56])
            {
              'text': '$_customer 11:44:00',
              'confidence': 1.0,
              'x': .27,
              'y': y,
              'width': .25,
              'height': .02,
            },
        ],
        'visualRegions': [
          for (final y in [.31, .59])
            {
              'x': .27326,
              'y': y,
              'width': .11181,
              'height': .16,
              'confidence': 1.0,
            },
        ],
      });
      final result = await flow.registrar.register(
          evidence: source.evidence,
          inspection: inspection,
          cards: inspection.visualRegions,
          visibleText: const [],
          frontier: const {'empty': true},
          registerOnly: true,
          nextMessageId: () => 'separate-same-second:${++flow.sequence}');
      expect(result.parents, hasLength(2));
      expect(
          result.parents.values.map((p) => p.receiptId).toSet(), hasLength(2));
      expect(
          result.parents.values.map((p) => p.messageId).toSet(), hasLength(2));
      expect(await flow.work(), hasLength(2));
      expect(await flow.owners(), hasLength(2));
      final repeated = await flow.registrar.register(
          evidence: source.evidence,
          inspection: inspection,
          cards: inspection.visualRegions,
          visibleText: const [],
          frontier: const {'empty': true},
          registerOnly: true);
      expect(repeated.parents.values.map((p) => p.messageId).toSet(),
          result.parents.values.map((p) => p.messageId).toSet());
      expect(await flow.work(), hasLength(2));
    });

    test('same file resent in a new automation session keeps its own business',
        () async {
      final first = (await flow.replay('loaded'))!;
      await flow.complete(first);
      await flow.formal(first);
      final firstSession = db.currentAutomationSessionId;
      await db.beginAutomationSession(
          startedAt: DateTime.utc(2026, 11, 9, 3, 44, 7));
      final resent =
          (await flow.replay('loaded', suffix: '-new-session', metadata: {
        'capturedAtMs':
            DateTime.utc(2026, 11, 9, 3, 44, 8).millisecondsSinceEpoch,
        'unreadArrivalKey': 'arrival:new-session-same-file',
      }))!;
      expect(db.currentAutomationSessionId, isNot(firstSession));
      expect(resent.receiptId, isNot(first.receiptId));
      expect(resent.messageId, isNot(first.messageId));
      expect(await flow.owners(), hasLength(1));
      expect(await flow.work(), hasLength(1));
      expect(await db.isMessageFormallyAnswered(_customer, resent.messageId),
          isFalse);
    });
  });
}

void _homeTests() {
  testWidgets('CaptureHome recorded video has one formal despite late old OCR',
      (tester) async {
    const channel = MethodChannel('jd-v42-home-recorded-video');
    const other = 'jd_v42_second_customer';
    late Directory root;
    late CaptureDatabase db;
    final frames = <String, Map<String, Object?>>{};
    final imageBytes = <String, List<int>>{};
    final observed = <String, int>{};
    final manifests = <String, String>{};
    final at = <String, int>{};
    final calls = <String>[];
    final sent = <String>[];
    final generations = <List<Map<String, dynamic>>>[];
    final releaseCrop = Completer<void>();
    final releaseOldOcr = Completer<void>();
    final releaseVideoGeneration = Completer<void>();
    final generatedCustomers = <String>[];
    final formalCustomers = <String>[];
    var otherArrived = false;
    var otherFormalSent = false;
    var videoGenerationStarted = false;
    var phase = 'baseline';
    var cropStarted = false;
    var oldOcrStarted = false;
    var formalSent = false;
    var stopped = false;
    var active = _customer;
    var monotonic = 0;
    late String cover;
    late String video;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_v42_home_video_');
      db = CaptureDatabase(storageRoot: root);
      for (final name in ['baseline', 'gray-play', 'loaded', 'gray-clipped']) {
        frames[name] = Map<String, Object?>.from(
            jsonDecode(await File('$_fixtures/$name.ocr.json').readAsString())
                as Map);
        imageBytes[name] = await File('$_fixtures/$name.png').readAsBytes();
      }
      final jdNow = DateTime.now().toUtc().add(const Duration(hours: 8));
      final clock =
          '${jdNow.hour.toString().padLeft(2, '0')}:${jdNow.minute.toString().padLeft(2, '0')}:${jdNow.second.toString().padLeft(2, '0')}';
      frames['b-text'] = {
        'activeCustomerId': other,
        'windowId': 17539,
        'imageWidth': 2880,
        'imageHeight': 1626,
        'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .79},
        'observations': [
          {
            'text': '$other $clock',
            'confidence': 1.0,
            'x': .27,
            'y': .30,
            'width': .25,
            'height': .018
          },
          {
            'text': 'How do I connect USB?',
            'confidence': 1.0,
            'x': .28,
            'y': .35,
            'width': .25,
            'height': .02
          },
        ],
        'visualRegions': <Object>[],
      };
      imageBytes['b-text'] = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=');
      video = (await File('test/fixtures/v35_media/unbound-video-original.mp4')
              .copy('${root.path}/native-complete-video.mp4'))
          .path;
      cover = base64Encode(
          await File('test/fixtures/v35_media/unbound-video-cover.jpg')
              .readAsBytes());
    });
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() {
      if (!releaseCrop.isCompleted) releaseCrop.complete();
      if (!releaseOldOcr.isCompleted) releaseOldOcr.complete();
      if (!releaseVideoGeneration.isCompleted) {
        releaseVideoGeneration.complete();
      }
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      final args = Map<String, Object?>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'prepareRunPermissions':
        case 'runPermissionsStatus':
          return {'ready': true};
        case 'status':
          return {'trusted': true};
        case 'ensureReceptionWindow':
          return {'opened': true};
        case 'listConversationRows':
          return [
            if (otherArrived)
              {
                'customer': other,
                'identitySource': 'ax',
                'unread': !otherFormalSent,
                'redClockPresent': !otherFormalSent,
                'evidenceAvailable': true,
                'unreadEvidence': otherFormalSent ? 0 : 20,
              },
            {
              'customer': _customer,
              'identitySource': 'ax',
              'unread': false,
              'redClockPresent': phase != 'baseline' && !formalSent,
              'evidenceAvailable': true,
              'unreadEvidence': 0,
            }
          ];
        case 'openConversation':
          active = args['expectedCustomer']! as String;
          expect([_customer, other], contains(active));
          return {'opened': true, 'customer': active};
        case 'scrollConversation':
          return {'scrolled': true};
        case 'captureViewportEvidence':
          final customer = args['expectedCustomer'] as String? ?? active;
          final name = customer == other ? 'b-text' : phase;
          final history = args['historyCutoffMs'] != null ||
              (args['historyCutoffs'] as Map? ?? const {})
                  .containsKey(customer);
          final id = '${history ? 'history-' : ''}home-$name';
          final source = frames[name]!;
          final directory = await Directory('${root.path}/capture_evidence')
              .create(recursive: true);
          final image = File('${directory.path}/$id.png');
          await image.writeAsBytes(imageBytes[name]!);
          final manifest = File('${directory.path}/$id.json');
          manifests[manifest.path] = name;
          final stamp = at.putIfAbsent(
              id,
              () => name == 'gray-clipped'
                  ? at['home-gray-play']! - 1
                  : DateTime.now().millisecondsSinceEpoch);
          final metadata = <String, Object?>{
            'evidenceId': id,
            'customer': customer,
            'automationSessionId': db.currentAutomationSessionId,
            'capturedAtMs': stamp,
            'windowId': source['windowId'],
            'imageWidth': source['imageWidth'],
            'imageHeight': source['imageHeight'],
            'chatRegion': source['chatRegion'],
            'imagePath': image.path,
            'manifestPath': manifest.path,
            'pngSHA256': sha256.convert(imageBytes[name]!).toString(),
            'chatContentSHA256': 'recorded-$name',
            'recordedEvidenceId': source['evidenceId'],
            if (history)
              'historyCutoffMs': args['historyCutoffMs'] ??
                  (args['historyCutoffs'] as Map)[customer],
          };
          await manifest.writeAsString(jsonEncode(metadata));
          return metadata;
        case 'inspectViewportEvidence':
          final name = manifests[args['manifestPath']]!;
          observed.update(name, (n) => n + 1, ifAbsent: () => 1);
          if (name == 'gray-clipped') {
            oldOcrStarted = true;
            await releaseOldOcr.future;
          }
          final metadata = jsonDecode(
                  await File(args['manifestPath']! as String).readAsString())
              as Map;
          return {
            ...frames[name]!,
            'evidenceId': metadata['evidenceId'],
            'capturedAtMs': metadata['capturedAtMs'],
            'pngBase64': base64Encode(imageBytes[name]!),
          };
        case 'captureRecentCachedMedia':
          return {'kind': 'none'};
        case 'recentMediaCacheRevision':
          return {'revision': 'same-recorded-video'};
        case 'cropViewportEvidence':
          cropStarted = true;
          await releaseCrop.future;
          return {
            'kind': 'video',
            'reason': 'pixel_matched_same_chat_video_companion',
            'captureSource': 'frozen-frame-video-cache',
            'playbackOverlayDetected': true,
            'visualFingerprint': '1234567890abcdef',
            'dataBase64': cover,
            'cardPreviewDataBase64': cover,
            'video': {
              'path': video,
              'originalName': 'native-complete-video.mp4',
              'mimeType': 'video/mp4'
            },
          };
        case 'transcribeAudio':
          return {
            'transcript': 'The printer is not feeding paper.',
            'language': 'en-US',
            'confidence': 1.0,
            'speechDetected': true
          };
        case 'checkDeliveryReadiness':
          return {
            'ready': active == args['expectedCustomer'],
            'customer': active
          };
        case 'sendDraftOnce':
          final customer = args['expectedCustomer']! as String;
          expect(active, customer);
          final reply = args['reply']! as String;
          sent.add(reply);
          if (!isHoldingReply(reply)) {
            formalCustomers.add(customer);
            if (customer == _customer) {
              formalSent = true;
            }
            if (customer == other) {
              otherFormalSent = true;
            }
          }
          return {
            'sent': true,
            'customer': customer,
            'activeCustomerId': customer,
            'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch,
            'redClockPresentAfterSend': false,
            'redClockObservedAtMs': DateTime.now().millisecondsSinceEpoch
          };
      }
      return <String, Object?>{};
    });
    Future<void> tick({int steps = 1}) async {
      for (var i = 0; i < steps; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        monotonic += 10;
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> until(bool Function() ready, {int steps = 1000}) async {
      for (var i = 0; i < steps && !ready(); i++) {
        await tick();
      }
      expect(ready(), isTrue,
          reason: 'phase=$phase observed=$observed '
              'crop=$cropStarted old=$oldOcrStarted sends=$sent generations=$generations '
              'calls=${calls.take(45).toList()}');
    }

    Future<T> query<T>(Future<T> Function() read) async {
      T? value;
      Object? failure;
      var done = false;
      await tester.runAsync(() async {
        unawaited(read().then((result) {
          value = result;
          done = true;
        }, onError: (Object error) {
          failure = error;
          done = true;
        }));
      });
      await until(() => done);
      if (failure != null) throw failure!;
      return value as T;
    }

    Future<List<Map<String, Object?>>> work() => query(() async =>
        (await db.database).query('automation_session_messages',
            where: 'session_id=? AND user_id=?',
            whereArgs: [db.currentAutomationSessionId, _customer]));
    Future<void> waitWork(int count) async {
      for (var i = 0; i < 500; i++) {
        if ((await work()).length == count) return;
        await tick();
      }
      expect(await work(), hasLength(count));
    }

    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
      database: db,
      adapter: MacOSCaptureAdapter(channel: channel),
      redClockTracker: RedClockTracker(monotonicMs: () => monotonic),
      scanIntervalOverride: const Duration(milliseconds: 150),
      generateDraftOverride: (customer, database, end, cancellation) async {
        final inputs = (await database.generationMessages(customer.userId,
                batchEndMessageId: end))
            .where((m) => m['direction'] == 'incoming')
            .toList();
        generations.add(inputs);
        generatedCustomers.add(customer.userId);
        expect(inputs, hasLength(1));
        if (customer.userId == other) {
          expect(inputs.single['body'], 'How do I connect USB?');
          expect(inputs.single['media_receipt_id'], isNull);
          return AiDraft.fromJson({
            'reply': 'Connect the supplied USB cable directly to the computer.',
            'reply_purpose': 'substantive',
            'decision': 'draft',
            'confidence': 1,
            'risk_level': 'low',
            'model': 'controlled-v42-other-text',
            'auto_send_allowed': true,
          }, mediaBaseUrl: Uri());
        }
        expect(customer.userId, _customer);
        videoGenerationStarted = true;
        await releaseVideoGeneration.future;
        expect(inputs.single['media_receipt_id'], isNotNull);
        expect(
            (inputs.single['media'] as List)
                .whereType<Map>()
                .where((m) => m['type'] == 'video'),
            hasLength(1));
        final media = (inputs.single['media'] as List).cast<Map>();
        final descriptions = <String, String>{
          for (final item in media.where((m) => m['type'] == 'image'))
            item['path']! as String:
                'The decoded video frame shows the paper feed.',
        };
        // The production reply service persists every selected image analysis
        // before it returns; keep that same boundary in the controlled model.
        await (await database.history)
            .updateMediaDescriptions(customer.userId, descriptions);
        return AiDraft.fromJson({
          'reply':
              'Switch off the printer and reload the paper with the printable side facing correctly.',
          'reply_purpose': 'substantive',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-v42-home',
          'auto_send_allowed': true,
          'image_descriptions': [
            for (final item in media.where((m) => m['type'] == 'image'))
              {
                'path': item['path'],
                'description': 'The decoded video frame shows the paper feed.'
              }
          ],
        }, mediaBaseUrl: Uri());
      },
    )));
    await grantRunPermissions(tester);
    await until(() =>
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Start automation'))
            .onPressed !=
        null);
    await tester.runAsync(() => tester.tap(find.text('Start automation')));
    await until(() => (observed['baseline'] ?? 0) > 0);
    // Wait for the actual baseline file-to-ledger pass before exposing arrival.
    await tick(steps: 20);
    expect(await work(), isEmpty);
    phase = 'gray-play';
    await until(() => cropStarted);
    await waitWork(1);
    final parent = (await work()).single['message_id'];
    phase = 'loaded';
    await until(() => (observed['loaded'] ?? 0) > 0);
    await tick(steps: 20);
    expect(await work(), hasLength(1));
    releaseCrop.complete();
    await until(() => videoGenerationStarted);
    otherArrived = true;
    await until(() => otherFormalSent);
    expect(releaseVideoGeneration.isCompleted, isFalse,
        reason:
            'Another customer replies while the original video model is pending.');
    expect(await query(() => db.hasPendingUnanswered(other)), isFalse);
    phase = 'gray-clipped';
    await until(() => oldOcrStarted);
    releaseVideoGeneration.complete();
    // Formal delivery must not wait for unrelated/late OCR to finish.
    await until(() => formalSent);
    expect(releaseOldOcr.isCompleted, isFalse);
    releaseOldOcr.complete();
    await tick(steps: 55);
    final finalWork = await work();
    expect(finalWork, hasLength(1));
    expect(finalWork.single['message_id'], parent);
    expect(finalWork.single['response_state'], 'answered');
    expect(await query(() => db.hasPendingUnanswered(_customer)), isFalse);
    expect(generations, hasLength(2));
    expect(generatedCustomers.where((c) => c == _customer), hasLength(1));
    expect(generatedCustomers.where((c) => c == other), hasLength(1));
    expect(formalCustomers.where((c) => c == _customer), hasLength(1));
    expect(formalCustomers.where((c) => c == other), hasLength(1));
    expect(sent.where((reply) => !isHoldingReply(reply)), hasLength(2));
    expect(await query(() => db.hasPendingUnanswered(other)), isFalse);
    expect(
        (await query(() async => (await db.database).query(
            'customer_media_items',
            where:
                'customer=? AND admission_session_id=? AND message_id IS NOT NULL AND canonical_id IS NULL',
            whereArgs: [_customer, db.currentAutomationSessionId]))),
        hasLength(1));
    final delayed = await query(() async => (await db.database).query(
        'media_capture_audit',
        where: 'evidence_id=?',
        whereArgs: ['home-gray-clipped']));
    expect(delayed, isNotEmpty,
        reason: 'The old recorded frame must actually reach production audit.');
    expect(
        delayed.map((row) =>
            (jsonDecode(row['details']! as String) as Map)['parentMessageId']),
        everyElement(parent));
    await tester.runAsync(() => tester.tap(find.text('Stop automation')));
    stopped = true;
    await tick(steps: 15);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    expect(stopped, isTrue);
  });
}
