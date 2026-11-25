import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

import 'helpers/run_permissions.dart';

const _buyer = 'jd_41aeec7741d05';
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=';
const _oldReply = 'What issue are you having with your TD630G?';
const _newQuestion = 'How do I connect this printer to my computer?';
const _unrelatedOldQuestion =
    'An unrelated old question must not become new work.';

AiDraft _answer(String reply) => AiDraft.fromJson({
      'reply': reply,
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'controlled-discovery-fixture',
      'used_record_ids': [],
      'actions': [],
      'attachments': [],
      'auto_send_allowed': false,
    }, mediaBaseUrl: Uri());

class _DiscoveryFlow {
  _DiscoveryFlow(this.root, this.db, this.channel,
      {required this.videoRace,
      this.baselineMedia = false,
      this.chromeNoise = false,
      this.failBaselineOnce = false});
  final Directory root;
  final CaptureDatabase db;
  final MethodChannel channel;
  final bool videoRace, baselineMedia, chromeNoise, failBaselineOnce;
  final inspections = <int, int>{};
  final frameTimes = <int, int>{};
  final framePhases = <String, int>{};
  final generated = <List<Map<String, dynamic>>>[];
  final replies = <String>[];
  final scheduled = <String>[];
  final trace = <String>[];
  int phase = 0, captures = 0, crops = 0, baselineFailures = 0;
  bool running = false, newRed = false, backfillOnly = false;
  bool videoOriginalReady = false;
  File? originalVideo;
  bool selectedRedOnly = false;
  Completer<void>? sidebarGate;
  Completer<void>? generationGate;
  int backfillCaptures = 0;
  Map<String, dynamic> document = {};

  Map<String, Object?> _line(String text, double y,
          {double x = .275, double width = .28}) =>
      {
        'text': text,
        'confidence': 1.0,
        'x': x,
        'y': y,
        'width': width,
        'height': .018
      };

  Future<Map<String, dynamic>> inspection(int current) async {
    if (current == 99) {
      return {
        'windowId': 7,
        'activeCustomerId': _buyer,
        'pngBase64': _png,
        'imageWidth': 2880,
        'imageHeight': 1626,
        'capturedAtMs': frameTimes[current],
        'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .81},
        'observations': [
          _line('$_buyer 13:39:59', .205),
          _line(_unrelatedOldQuestion, .235, width: .4),
          _line('$_buyer 13:40:00', .27),
          _line('$_buyer 13:51:02', .41),
        ],
        'visualRegions': [
          {'x': .27, 'y': .30, 'width': .115, 'height': .08, 'confidence': 1.0},
          {'x': .27, 'y': .44, 'width': .115, 'height': .20, 'confidence': 1.0},
        ],
      };
    }
    if (videoRace && current > 0) {
      final name =
          current == 1 ? 'video-gray-after-reply' : 'video-cover-after-reply';
      return {
        ...jsonDecode(await File('test/fixtures/v34_discovery/$name.json')
            .readAsString()) as Map<String, dynamic>,
        'windowId': 7,
        'pngBase64': _png,
        'capturedAtMs': frameTimes[current],
      };
    }
    return {
      'windowId': 7,
      'activeCustomerId': _buyer,
      'pngBase64': _png,
      'imageWidth': 2880,
      'imageHeight': 1626,
      'capturedAtMs': frameTimes[current],
      'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .81},
      'observations': [
        _line('$_buyer 13:50:46', .275),
        _line('with my TD630G', .31),
        if (baselineMedia) _line('$_buyer 13:50:47', .37),
        if (!videoRace) ...[
          _line('13:50:48 格志打印机小耿', .68, x: .57, width: .15),
          _line('Previously answered context.', .72, x: .50, width: .22),
          if (current > 0) ...[
            _line('$_buyer 13:51:04', .76),
            _line(_newQuestion, .79, width: .40),
          ],
        ],
      ],
      'visualRegions': [
        if (baselineMedia)
          {'x': .27, 'y': .4, 'width': .115, 'height': .24, 'confidence': 1.0}
      ],
    };
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      trace.add(call.method);
      final args = call.arguments as Map? ?? const {};
      switch (call.method) {
        case 'prepareRunPermissions':
        case 'runPermissionsStatus':
          return {'ready': true};
        case 'status':
          return {'trusted': true};
        case 'ensureReceptionWindow':
          return {'opened': true};
        case 'listConversationRows':
          if (sidebarGate case final gate? when !gate.isCompleted) {
            await gate.future;
          }
          return [
            {
              'customer': _buyer,
              'identitySource': 'ax',
              'unread':
                  !selectedRedOnly && ((videoRace && phase == 0) || newRed),
              'unreadEvidence': (videoRace && phase == 0) || newRed ? 20 : 0,
              'redClockPresent': (videoRace && phase == 0) || newRed,
              'unreadAgeSeconds':
                  (videoRace && phase == 0) || newRed ? 0 : null,
              'evidenceAvailable': true
            }
          ];
        case 'openConversation':
          return {'opened': true, 'customer': _buyer};
        case 'captureViewportEvidence':
          final isBackfill = args['historyCutoffMs'] != null;
          if (backfillOnly && !isBackfill) {
            throw PlatformException(code: 'snapshot_chat_missing');
          }
          captures++;
          // Only the dedicated acquisition test supplies a synthetic image
          // history page. The recorded video case keeps its actual video
          // pixels/type when the ordinary backfill worker revisits it.
          final current = isBackfill && backfillOnly ? 99 : phase;
          if (isBackfill) backfillCaptures++;
          // Native evidence IDs already use only the AX transcript pixels;
          // sidebar/UI changes return the same immutable chat evidence.
          final name = 'frame-$current';
          final evidenceDirectory =
              await Directory('${root.path}/capture_evidence')
                  .create(recursive: true);
          final image = File('${evidenceDirectory.path}/$name.png');
          final manifest = File('${evidenceDirectory.path}/$name.json');
          if (videoRace && current > 0) {
            final recordedName = current == 1
                ? 'video-gray-after-reply'
                : 'video-cover-after-reply';
            await image.writeAsBytes(
                await File('test/fixtures/v34_discovery/$recordedName.png')
                    .readAsBytes());
          } else {
            await image.writeAsBytes(base64Decode(_png));
          }
          framePhases[manifest.path] = current;
          frameTimes.putIfAbsent(
              current, () => DateTime.now().millisecondsSinceEpoch);
          final metadata = <String, Object?>{
            'evidenceId': name,
            'customer': _buyer,
            'automationSessionId': db.currentAutomationSessionId,
            'windowId': 7,
            'imageWidth': 2880,
            'imageHeight': 1626,
            'chatRegion': {
              'left': .24027777777777778,
              'right': .7479166666666667,
              'top': .20418204182041821,
              'bottom': .8044280442804428,
            },
            'chatContentSHA256': 'transcript-$current',
            if (chromeNoise) 'outsideChatNoise': captures,
            'capturedAtMs': frameTimes[current],
            'imagePath': image.path,
            'manifestPath': manifest.path,
            if (isBackfill) 'historyCutoffMs': args['historyCutoffMs'],
          };
          await manifest.writeAsString(jsonEncode(metadata));
          return metadata;
        case 'inspectViewportEvidence':
          final current = framePhases[args['manifestPath']]!;
          inspections.update(current, (v) => v + 1, ifAbsent: () => 1);
          if (failBaselineOnce && current == 0 && baselineFailures++ == 0) {
            throw PlatformException(code: 'controlled_ocr_failure');
          }
          return inspection(current);
        case 'captureRecentCachedMedia':
          return {'kind': 'none'};
        case 'recentMediaCacheRevision':
          return {
            'revision':
                videoOriginalReady ? 'owned-original-ready' : 'preview-only'
          };
        case 'scrollConversation':
          return {'scrolled': true};
        case 'cropViewportEvidence':
          crops++;
          final current = framePhases[args['manifestPath']] ?? phase;
          if (current == 99) {
            return {
              'kind': 'image',
              'dataBase64': _png,
              'mimeType': 'image/png',
              'extension': 'png',
              'captureSource': 'jd-image-cache',
              'visualFingerprint': '1111111111111111'
            };
          }
          final recordedName = current == 1
              ? 'video-gray-after-reply'
              : 'video-cover-after-reply';
          return {
            'kind': 'video',
            'foregroundFraction': videoRace && current == 1 ? 0.0 : .758,
            'visualFingerprint': videoRace
                ? current == 1
                    ? '00000119ffffffff'
                    : 'fde181f19fe11f03'
                : '0000000000000000',
            if (videoRace)
              'dataBase64': base64Encode(await File(
                      'test/fixtures/v34_discovery/$recordedName-card.png')
                  .readAsBytes()),
            'mimeType': 'image/png',
            'extension': 'png',
            'captureSource': 'frozen-window-crop',
            'playbackOverlayDetected': true,
            'reason': videoOriginalReady
                ? 'controlled_native_owned_original'
                : 'original_pending',
            if (videoRace && videoOriginalReady)
              'video': {
                // Native ownership is mocked here; actual recorded bytes run
                // through the real frame extraction/readiness pipeline.
                'path': originalVideo!.path,
                'originalName': 'controlled-owned-original.mp4',
                'mimeType': 'video/mp4'
              },
          };
        case 'transcribeAudio':
          return {
            'transcript': '',
            'language': 'en-US',
            'speechDetected': false
          };
        case 'sendDraftOnce':
          final reply = args['reply']! as String;
          replies.add(reply);
          if (videoRace && phase == 0) phase = 1;
          return {
            'sent': true,
            'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch
          };
      }
      return <String, Object?>{};
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
      database: db,
      adapter: MacOSCaptureAdapter(channel: channel),
      scanIntervalOverride: const Duration(milliseconds: 120),
      mediaCacheProbeIntervalOverride: const Duration(milliseconds: 30),
      draftSchedulerOverride: videoRace ? null : scheduled.add,
      generateDraftOverride: (c, d, end, cancellation) async {
        final input =
            await d.generationMessages(c.userId, batchEndMessageId: end);
        generated
            .add(input.where((m) => m['direction'] == 'incoming').toList());
        if (generationGate case final gate? when !gate.isCompleted) {
          await gate.future;
        }
        return _answer(
            generated.length == 1 ? _oldReply : 'Controlled video task reply.');
      },
    )));
    await grantRunPermissions(tester);
    await tester.runAsync(() => tester.tap(find.text('Start automation')));
    running = true;
  }

  Future<void> tick(WidgetTester tester, {int steps = 1}) async {
    for (var i = 0; i < steps; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final file = File('${root.path}/$_buyer.json');
        if (await file.exists()) {
          document =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        }
      });
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> until(WidgetTester tester, bool Function() ready,
      {int steps = 500}) async {
    for (var i = 0; i < steps && !ready(); i++) {
      await tick(tester);
    }
    expect(ready(), isTrue,
        reason: 'phase=$phase inspections=$inspections crops=$crops '
            'generated=${generated.length} replies=$replies calls=${trace.take(35).toList()}');
  }

  Future<T> query<T>(WidgetTester tester, Future<T> Function() read) async {
    var ready = false;
    T? value;
    Object? error;
    await tester.runAsync(() async {
      unawaited(read().then((result) {
        value = result;
        ready = true;
      }, onError: (Object failure) {
        error = failure;
        ready = true;
      }));
    });
    await until(tester, () => ready);
    if (error != null) throw error!;
    return value as T;
  }

  Future<void> close(WidgetTester tester) async {
    if (running) {
      await tester.runAsync(() => tester.tap(find.text('Stop automation')));
    }
    await tick(tester, steps: 15);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

void main() {
  Future<_DiscoveryFlow> fixture(WidgetTester tester, String name,
      {bool videoRace = false,
      bool baselineMedia = false,
      bool chromeNoise = false,
      bool failBaselineOnce = false}) async {
    late _DiscoveryFlow flow;
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('jd_v34_$name');
      final db = CaptureDatabase(storageRoot: root);
      await db.database;
      await db.history;
      flow = _DiscoveryFlow(root, db, MethodChannel('v34.$name'),
          videoRace: videoRace,
          baselineMedia: baselineMedia,
          chromeNoise: chromeNoise,
          failBaselineOnce: failBaselineOnce);
      if (videoRace) {
        flow.originalVideo =
            await File('test/fixtures/v35_media/unbound-video-original.mp4')
                .copy('${root.path}/controlled-owned-original.mp4');
      }
    });
    return flow;
  }

  testWidgets(
      'video arriving with old reply is discovered without a new AX red marker',
      (tester) async {
    final f = await fixture(tester, 'video-race', videoRace: true);
    await f.mount(tester);
    await f.until(tester, () => f.replies.length == 1 && f.crops > 0);
    expect(f.generated.first.single['body'], 'with my TD630G');
    expect(f.inspections[1], greaterThan(0));
    expect(f.crops, greaterThan(0));
    expect(f.replies.where(isHoldingReply), isEmpty);
    expect(
        await f.query(tester, () => f.db.hasPendingUnanswered(_buyer)), isTrue,
        reason: 'A received video without usable content is still unanswered');
    expect(f.generated, hasLength(1),
        reason: 'A loading card must not generate an early loading reply');
    f.phase = 2;
    final before = f.crops;
    await f.until(tester, () => f.crops > before);
    expect(
        (await f.query(tester,
            () => CustomerMediaInventory(f.db).pendingMediaForTask(_buyer))),
        hasLength(1),
        reason: 'A loading cover does not end original acquisition');
    await f.until(
        tester,
        () => (f.document['messages'] as List? ?? const [])
            .whereType<Map>()
            .expand((m) => (m['media'] as List? ?? const []).whereType<Map>())
            .any((m) => m['visual_fingerprint'] == 'fde181f19fe11f03'));
    await f.tick(tester, steps: 25);
    expect(f.replies, [_oldReply]);
    expect(f.generated, hasLength(1),
        reason: 'A video cover alone does not make the video analyzable');
    f.videoOriginalReady = true;
    await f.until(tester, () => f.replies.length >= 2);
    final inputs = f.generated
        .skip(1)
        .expand((m) => m)
        .where((m) => m['media_receipt_id'] != null)
        .toList();
    expect(inputs.map((m) => m['id']).toSet(), hasLength(1),
        reason:
            'A loading cover and its real pixels belong to one customer input');
    // Native send completion precedes the local answer transaction. A queue
    // can also be empty while its frozen draft owns the input, so wait for
    // positive formal evidence instead of treating queue absence as completion.
    var formallyAnswered = false;
    for (var i = 0; i < 200 && !formallyAnswered; i++) {
      formallyAnswered = await f.query(
          tester,
          () => f.db.isMessageFormallyAnswered(
              _buyer, inputs.first['id']! as String));
      if (!formallyAnswered) await f.tick(tester);
    }
    expect(formallyAnswered, isTrue);
    expect(
        inputs.any((m) => (m['media'] as List? ?? const [])
            .whereType<Map>()
            .any((media) => media['capture_source'] == 'jd_video_frame_1fps')),
        isTrue,
        reason: 'The actual video content must reach the formal reply input');
    expect(f.generated.length, inInclusiveRange(2, 3),
        reason: 'Only a genuine visual upgrade may generate one follow-up');
    expect(f.replies.where(isHoldingReply), isEmpty);
    expect(await f.query(tester, () => f.db.hasPendingUnanswered(_buyer)),
        isFalse);
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  for (final selected in [false, true]) {
    testWidgets(
        'Start awaits AX red ownership before passive baseline (selected=$selected)',
        (tester) async {
      final f =
          await fixture(tester, 'startup-ax-race-$selected', videoRace: true);
      f.selectedRedOnly = selected;
      f.sidebarGate = Completer<void>();
      f.generationGate = Completer<void>();
      await f.mount(tester);
      await f.tick(tester, steps: 10);
      expect(f.captures, 0,
          reason:
              'An unobserved initial red row must not race passive history classification');
      f.sidebarGate!.complete();
      await f.until(tester, () => f.generated.isNotEmpty);
      final pending =
          await f.query(tester, () => f.db.processingMessages(_buyer));
      final pendingQuestion = pending
          .where((m) => m['direction'] == 'incoming')
          .singleWhere((m) => m['body'] == 'with my TD630G');
      expect(pendingQuestion['capture_evidence_id'], 'frame-0');
      expect(await f.query(tester, () => f.db.hasPendingUnanswered(_buyer)),
          isTrue);
      f.generationGate!.complete();
      await f.until(
          tester,
          () =>
              f.replies.length == 1 &&
              f.crops > 0 &&
              (f.document['messages'] as List? ?? const [])
                  .whereType<Map>()
                  .any((message) =>
                      message['body'] == 'with my TD630G' &&
                      message['capture_evidence_id'] == 'frame-1'));
      expect(f.generated, hasLength(1),
          reason: 'Newly discovered loading video stays pending, not replied');
      final anchor = await f.query(
          tester,
          () async => (await f.db.database).query('capture_discovery_state',
              where: 'session_id=? AND customer=?',
              whereArgs: [f.db.currentAutomationSessionId, _buyer]));
      expect(anchor.single['kind'], 'live');
      final firstQuestion = (f.document['messages'] as List)
          .whereType<Map>()
          .firstWhere((m) => m['body'] == 'with my TD630G');
      expect(firstQuestion['capture_purpose'], isNot('history_only'));
      expect(firstQuestion['capture_evidence_id'], 'frame-1',
          reason:
              'Re-observing the question in the video frame preserves exact latest-frame provenance');
      expect(
          await f.query(
              tester,
              () => f.db.isMessageFormallyAnswered(
                  _buyer, firstQuestion['id']! as String)),
          isTrue);
      expect(
          await f.query(tester,
              () => CustomerMediaInventory(f.db).pendingMediaForTask(_buyer)),
          hasLength(1),
          reason:
              'The newly discovered video keeps its original acquisition task');
      await f.close(tester);
    }, skip: !Platform.isMacOS);
  }

  for (final media in [false, true]) {
    testWidgets(
        'passive Start baseline stays historical; later no-red text queues (media=$media)',
        (tester) async {
      final f = await fixture(tester, 'passive-$media', baselineMedia: media);
      await f.mount(tester);
      await f.until(
          tester, () => (f.document['messages'] as List? ?? []).isNotEmpty);
      await f.tick(tester, steps: 20);
      expect(f.inspections[0], 1);
      expect(f.crops, 0,
          reason: 'Baseline must not download or decode old media');
      expect(f.scheduled, isEmpty);
      expect(await f.query(tester, () => f.db.hasPendingUnanswered(_buyer)),
          isFalse);
      f.phase = 1;
      await f.until(tester, () => f.scheduled.isNotEmpty);
      final work = await f.query(tester, () => f.db.processingMessages(_buyer));
      expect(
          work.where((m) => m['direction'] == 'incoming').map((m) => m['body']),
          [_newQuestion]);
      expect(await f.query(tester, () => f.db.platformResponseCycle(_buyer)),
          isNull);
      expect(f.replies, isEmpty);
      await f.close(tester);
    }, skip: !Platform.isMacOS);
  }

  testWidgets(
      'sidebar pixel noise with identical chat hash does not re-OCR or reactivate baseline',
      (tester) async {
    final f = await fixture(tester, 'same-chat-hash', chromeNoise: true);
    await f.mount(tester);
    await f.until(
        tester, () => (f.document['messages'] as List? ?? []).isNotEmpty);
    await f.tick(tester, steps: 50);
    expect(f.captures, greaterThan(5));
    expect(f.inspections[0], 1);
    expect(f.scheduled, isEmpty);
    expect(f.replies, isEmpty);
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  testWidgets(
      'failed baseline remains recoverable and later frame cannot activate old history',
      (tester) async {
    final f = await fixture(tester, 'baseline-retry', failBaselineOnce: true);
    await f.mount(tester);
    await f.until(tester, () => f.baselineFailures > 0);
    f.phase = 1;
    await f.tick(tester, steps: 15);
    expect(f.scheduled, isEmpty,
        reason: 'Discovery must not overtake an unregistered baseline');
    await f.query(
        tester,
        () async => (await f.db.database).update(
            'capture_evidence', {'retry_at_ms': 0},
            where: 'id=?', whereArgs: ['frame-0']));
    await f.until(tester, () => f.scheduled.isNotEmpty);
    expect(f.inspections[0], greaterThanOrEqualTo(2));
    final work = await f.query(tester, () => f.db.processingMessages(_buyer));
    expect(
        work.where((m) => m['direction'] == 'incoming').map((m) => m['body']),
        [_newQuestion]);
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  testWidgets(
      'a genuine new AX red can recover business while the passive baseline is unreadable',
      (tester) async {
    final f =
        await fixture(tester, 'baseline-red-bypass', failBaselineOnce: true);
    await f.mount(tester);
    await f.until(tester, () => f.baselineFailures > 0);
    f.phase = 1;
    f.newRed = true;
    await f.until(tester, () => f.scheduled.isNotEmpty);
    expect(f.inspections[1], greaterThan(0));
    final work = await f.query(tester, () => f.db.processingMessages(_buyer));
    expect(
        work.where((m) => m['direction'] == 'incoming').map((m) => m['body']),
        contains(_newQuestion));
    expect(
        (await f.query(
            tester, () => f.db.platformResponseCycle(_buyer)))?['state'],
        'waiting');
    await f.close(tester);
  }, skip: !Platform.isMacOS);

  for (final unfinished in [true, false]) {
    testWidgets(
        'backfill activates only an actual unfinished acquisition (pending=$unfinished)',
        (tester) async {
      final f = await fixture(tester, 'acquisition-backfill-$unfinished');
      await f.mount(tester);
      await f.until(
          tester, () => (f.document['messages'] as List? ?? []).isNotEmpty);
      await f.tick(tester, steps: 20);
      f.backfillOnly = true;
      late String messageId;
      var initialRevision = 0;
      await f.query(tester, () async {
        final inventory = CustomerMediaInventory(f.db);
        final at = DateTime.now().toUtc();
        f.frameTimes[99] = at.millisecondsSinceEpoch;
        final sender = const OcrCaptureExtractor()
            .mediaClockForRegion(
                OcrInspection.fromMap(await f.inspection(99)),
                const OcrVisualRegion(
                    x: .27, y: .44, width: .115, height: .20, confidence: 1))
            .sentAt!;
        final receipt = await inventory.observe(
            customer: _buyer,
            evidenceId: 'initial-image',
            observedAt: at,
            senderAt: sender,
            slot: 0,
            region: [.27, .4, .115, .24],
            current: true);
        await f.db.admitMediaMessage(_buyer,
            receiptId: receipt,
            evidenceId: 'initial-image',
            occurrenceKey: 'current-unanswered-image',
            receivedAt: at,
            senderAt: sender);
        await inventory.classify(receipt, 'image',
            fingerprint: '1111111111111111');
        messageId = 'media-pending:$receipt';
        final image = await File('${f.root.path}/initial-image.png')
            .writeAsBytes(base64Decode(_png));
        final capture = CapturedConversation(
            stableKey: _buyer,
            customerName: _buyer,
            customerExternalId: _buyer,
            capturedAt: at,
            automationSessionId: f.db.currentAutomationSessionId,
            messages: [
              CapturedMessage(
                  stableId: messageId,
                  direction: 'incoming',
                  body: '[Customer sent image]',
                  sentAt: sender,
                  axPath: 'fixture',
                  mediaReceiptId: receipt,
                  media: [
                    CapturedMedia(
                        type: 'image',
                        path: image.path,
                        captureSource: unfinished
                            ? 'verified_window_crop'
                            : 'jd_image_cache',
                        isPartial: unfinished,
                        visualFingerprint: '1111111111111111')
                  ])
            ]);
        await f.db.saveCapture(capture);
        await inventory.persist(capture, currentTaskOnly: true);
        await (await f.db.database).update('automation_session_messages',
            {'response_state': unfinished ? 'pending' : 'answered'},
            where: 'session_id=? AND user_id=? AND message_id=?',
            whereArgs: [f.db.currentAutomationSessionId, _buyer, messageId]);
        await f.db.ensurePendingForUnanswered(_buyer);
        initialRevision =
            ((await f.db.processingMessages(_buyer, includeAnswered: true))
                        .singleWhere((message) => message['id'] == messageId)[
                    'reply_work_revision'] as num)
                .toInt();
        // This task fixture supplies an already proved card ancestry. The
        // cache's one-pixel payload and sender clock cannot establish it.
        final audit = MediaCaptureAudit(f.db);
        final observation = await audit.discover(
            ViewportEvidence({
              'evidenceId': 'frame-99',
              'customer': _buyer,
              'capturedAtMs': at.millisecondsSinceEpoch,
              'automationSessionId': f.db.currentAutomationSessionId,
              'imagePath': image.path,
            }),
            const OcrVisualRegion(
                x: .27, y: .44, width: .115, height: .20, confidence: 1));
        await audit.bindParent(observation,
            receiptId: receipt, messageId: messageId);
        await CaptureEvidenceStore(f.db)
            .requestBackfill(_buyer, DateTime.now().toUtc());
        return true;
      });
      expect(await f.query(tester, () => f.db.hasPendingUnanswered(_buyer)),
          unfinished);
      expect(
          (await f.query(
                  tester,
                  () =>
                      CustomerMediaInventory(f.db).pendingMediaForTask(_buyer)))
              .isNotEmpty,
          unfinished);
      await f.until(tester, () => f.backfillCaptures > 0 && f.crops > 0);
      List<Map<String, Object?>> rows = [];
      List<Map<String, Object?>> target = [];
      for (var i = 0; i < 150; i++) {
        rows = await f.query(
            tester,
            () async => (await f.db.database).query('capture_evidence',
                where: 'id=?', whereArgs: ['frame-99']));
        target = await f.query(
            tester,
            () async => (await f.db.database).query('customer_media_items',
                where: 'message_id=?', whereArgs: [messageId]));
        if (rows.isNotEmpty &&
            const {'processed', 'media_waiting'}
                .contains(rows.single['state']) &&
            target.isNotEmpty &&
            target.single['state'] == 'ready') {
          break;
        }
        await f.tick(tester);
      }
      expect(target.single['state'], 'ready',
          reason:
              'The assigned original must actually finish; frame state alone is insufficient');
      expect(
          jsonDecode(target.single['media_json']! as String),
          contains(predicate((Object? item) =>
              item is Map &&
              item['capture_source'] == 'jd_image_cache' &&
              item['is_partial'] != true)));
      expect(rows.single['state'], unfinished ? 'media_waiting' : 'processed');
      final metadata = jsonDecode(rows.single['payload']! as String) as Map;
      expect(metadata['capturePurpose'], 'history_backfill');
      expect(metadata['replyActivationAllowed'], unfinished,
          reason:
              'A cache owner without an unfinished receipt cannot activate history');
      expect(metadata['acquisitionOnly'] == true, unfinished);
      await f.query(tester, () => f.db.repairSessionPendingWork(_buyer));
      final work = await f.query(tester, () => f.db.processingMessages(_buyer));
      expect(
          work.where((m) => m['direction'] == 'incoming').map((m) => m['id']),
          unfinished ? [messageId] : isEmpty);
      if (unfinished) {
        expect(work.single['reply_work_revision'], initialRevision + 1,
            reason:
                'Recovered full image upgrades the same still-pending input once');
        expect(f.crops, 1,
            reason:
                'Recovery-only backfill does not acquire unrelated old pictures');
        expect(
            (f.document['messages'] as List? ?? const [])
                .whereType<Map>()
                .where((m) => m['body'] == _unrelatedOldQuestion)
                .any((m) =>
                    (m['live_observed_session_ids'] as List? ?? const [])
                        .contains(f.db.currentAutomationSessionId)),
            isFalse,
            reason:
                'An old history observation must never acquire a live stamp or business task');
        final observations = await f.query(
            tester,
            () async => (await f.db.database).query('media_capture_audit',
                where: 'evidence_id=?', whereArgs: ['frame-99']));
        final oldPhoto = observations.singleWhere((row) =>
            ((jsonDecode(row['details']! as String) as Map)['region']
                as List)[1] ==
            .30);
        expect(oldPhoto['state'], 'discovered',
            reason:
                'The unrelated photo remains an observation, without an asset fetch');
      }
      expect(f.replies, isEmpty);
      await f.close(tester);
    }, skip: !Platform.isMacOS);
  }
}
