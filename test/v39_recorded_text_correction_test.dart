import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/red_clock_tracker.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

import 'helpers/run_permissions.dart';

const _buyer = 'jd_41aeec7741d05';
const _question = 'can you share me a video?';
const _formal = 'Yes. I can share the setup video for the ribbon check.';
const _fixtures = 'test/fixtures/v39_message_correction';

/// Recorded native pixels/OCR run through CaptureHome's actual discovery,
/// correction, generation queue and native-delivery acknowledgement path.
/// Only the native adapter and AI answer are controlled; no real customer UI
/// or CLI is contacted by this regression.
class _RecordedTextFlow {
  _RecordedTextFlow(this.root, this.db, this.channel);
  final Directory root;
  final CaptureDatabase db;
  final MethodChannel channel;
  final frames = <String, Map<String, dynamic>>{};
  final frameAt = <String, int>{};
  final nativeFrames = <String, String>{};
  final inspections = <String, int>{};
  final sends = <String>[];
  final generated = <List<Map<String, dynamic>>>[];
  final trace = <String>[];
  String phase = 'baseline';
  String? active;
  int monotonic = 0;
  bool holdingSent = false;
  bool formalSent = false;
  bool running = false;
  Map<String, dynamic> document = {};

  Future<void> mount(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (final name in [
        'baseline',
        'clipped-text',
        'early-full-text',
        'full-text'
      ]) {
        frames[name] =
            jsonDecode(await File('$_fixtures/$name.ocr.json').readAsString())
                as Map<String, dynamic>;
      }
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      trace.add(call.method);
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
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
            {
              'customer': _buyer,
              'identitySource': 'ax',
              'unread': false,
              'redClockPresent':
                  phase != 'baseline' && !holdingSent && !formalSent,
              'evidenceAvailable': true,
              'unreadEvidence': 0,
            }
          ];
        case 'openConversation':
          expect(args['expectedCustomer'], _buyer);
          active = _buyer;
          return {'opened': true, 'customer': _buyer};
        case 'scrollConversation':
          return {'scrolled': true};
        case 'captureViewportEvidence':
          final history = args['historyCutoffMs'] != null;
          final name = '${history ? 'history-' : ''}recorded-$phase';
          final source = frames[phase]!;
          final directory = await Directory('${root.path}/capture_evidence')
              .create(recursive: true);
          final image = File('${directory.path}/$name.png');
          final manifest = File('${directory.path}/$name.json');
          final bytes = await File('$_fixtures/$phase.png').readAsBytes();
          await image.writeAsBytes(bytes);
          nativeFrames[manifest.path] = phase;
          final receivedAt = frameAt.putIfAbsent(
              name, () => DateTime.now().millisecondsSinceEpoch);
          final metadata = {
            'evidenceId': name,
            'customer': _buyer,
            'automationSessionId': db.currentAutomationSessionId,
            'capturedAtMs': receivedAt,
            'imageWidth': source['imageWidth'],
            'imageHeight': source['imageHeight'],
            'windowId': source['windowId'],
            'chatRegion': source['chatRegion'],
            'imagePath': image.path,
            'manifestPath': manifest.path,
            'pngSHA256': sha256.convert(bytes).toString(),
            'chatContentSHA256': 'recorded-transcript-$phase',
            'recordedCapturedAtMs': source['capturedAtMs'],
            'recordedEvidenceId': source['evidenceId'],
            if (history) 'historyCutoffMs': args['historyCutoffMs'],
          };
          await manifest.writeAsString(jsonEncode(metadata));
          return metadata;
        case 'inspectViewportEvidence':
          final name = nativeFrames[args['manifestPath']]!;
          inspections.update(name, (n) => n + 1, ifAbsent: () => 1);
          final metadata = jsonDecode(
              await File(args['manifestPath'] as String).readAsString()) as Map;
          return {
            ...frames[name]!,
            'evidenceId': metadata['evidenceId'],
            'capturedAtMs': metadata['capturedAtMs'],
            'pngBase64':
                base64Encode(await File('$_fixtures/$name.png').readAsBytes()),
          };
        case 'captureRecentCachedMedia':
          return {'kind': 'none'};
        case 'recentMediaCacheRevision':
          return {'revision': 'no-new-customer-file'};
        case 'cropViewportEvidence':
          // This real customer sent text. An unknown crop cannot produce
          // an image/video original or satisfy media-analysis readiness.
          return {
            'kind': 'unknown',
            'captureSource': 'frozen-window-crop',
            'reason': 'no_media_object_in_clipped_text_bubble',
          };
        case 'checkDeliveryReadiness':
          return {
            'ready': active == args['expectedCustomer'],
            'customer': active,
          };
        case 'sendDraftOnce':
          expect(args['expectedCustomer'], _buyer);
          expect(active, _buyer);
          final reply = args['reply'] as String;
          sends.add(reply);
          if (isHoldingReply(reply)) {
            holdingSent = true;
          } else {
            formalSent = true;
          }
          return {
            'sent': true,
            'customer': _buyer,
            'activeCustomerId': _buyer,
            'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch,
            'redClockPresentAfterSend': false,
            'redClockObservedAtMs': DateTime.now().millisecondsSinceEpoch,
          };
      }
      return <String, Object?>{};
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
      database: db,
      adapter: MacOSCaptureAdapter(channel: channel),
      redClockTracker: RedClockTracker(monotonicMs: () => monotonic),
      scanIntervalOverride: const Duration(milliseconds: 150),
      generateDraftOverride: (customer, database, end, cancellation) async {
        final inputs = await database.generationMessages(customer.userId,
            batchEndMessageId: end);
        generated.add(inputs
            .where((message) => message['direction'] == 'incoming')
            .toList());
        return AiDraft.fromJson({
          'reply': _formal,
          'reply_purpose': 'substantive',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-recorded-text-correction',
          'auto_send_allowed': true,
          'actions': [],
          'attachments': [],
        }, mediaBaseUrl: Uri());
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
        final history = File('${root.path}/$_buyer.json');
        if (await history.exists()) {
          document =
              jsonDecode(await history.readAsString()) as Map<String, dynamic>;
        }
      });
      monotonic += 100;
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> until(WidgetTester tester, bool Function() ready,
      {int steps = 400}) async {
    for (var i = 0; i < steps && !ready(); i++) {
      await tick(tester);
    }
    expect(ready(), isTrue,
        reason: 'phase=$phase inspected=$inspections generated=$generated '
            'sends=$sends trace=${trace.take(50).toList()}');
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

  Future<List<Map<String, Object?>>> work(WidgetTester tester) => query(
      tester,
      () async => (await db.database).query('automation_session_messages',
          where: 'session_id=? AND user_id=?',
          whereArgs: [db.currentAutomationSessionId, _buyer],
          orderBy: 'activated_at_ms,rowid'));

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
  }
}

void main() {
  for (final holdingFirst in [false, true]) {
    testWidgets(
        'recorded clipped tutorial request becomes one text reply; holding first=$holdingFirst',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late _RecordedTextFlow flow;
      await tester.runAsync(() async {
        final root =
            await Directory.systemTemp.createTemp('jd_v39_recorded_text_');
        final db = CaptureDatabase(storageRoot: root);
        await db.database;
        await db.history;
        flow = _RecordedTextFlow(
            root, db, MethodChannel('v39.recorded-text.$holdingFirst'));
      });
      await flow.mount(tester);
      await flow.until(tester, () => (flow.inspections['baseline'] ?? 0) > 0);
      var baselineReady = false;
      for (var i = 0; i < 100 && !baselineReady; i++) {
        baselineReady = await flow.query(
            tester,
            () async => (await (await flow.db.database).query(
                    'capture_evidence',
                    where: "id='recorded-baseline' AND state='processed'"))
                .isNotEmpty);
        if (!baselineReady) await flow.tick(tester);
      }
      expect(baselineReady, isTrue);
      expect(await flow.work(tester), isEmpty,
          reason: 'Previously answered recorded context stays baseline.');
      flow.phase = 'clipped-text';
      List<Map<String, Object?>> unknown = [];
      for (var i = 0; i < 180 && unknown.isEmpty; i++) {
        await flow.tick(tester);
        unknown = await flow.work(tester);
      }
      expect(unknown, hasLength(1));
      expect(unknown.single['response_state'], 'pending');
      final parent = unknown.single['message_id'];
      final receivedAt = unknown.single['activated_at_ms'];
      expect(flow.generated, isEmpty,
          reason: 'An unreadable bubble is not enough for a formal answer.');
      if (holdingFirst) {
        await flow.until(tester, () => flow.holdingSent);
        expect(flow.sends.where(isHoldingReply), hasLength(1));
        expect(
            await flow.query(
                tester,
                () => flow.db
                    .isMessageFormallyAnswered(_buyer, parent as String)),
            isFalse);
        expect(await flow.query(tester, flow.db.unansweredWorkCounts),
            {_buyer: 1});
      }
      flow.phase = holdingFirst ? 'full-text' : 'early-full-text';
      await flow.until(tester, () => flow.formalSent);
      await flow.tick(tester, steps: 15);
      final completed = await flow.work(tester);
      expect(completed, hasLength(1));
      expect(completed.single['message_id'], parent);
      expect(completed.single['activated_at_ms'], receivedAt);
      expect(completed.single['input_kind'], 'text');
      expect(completed.single['response_state'], 'answered');
      expect(flow.generated, hasLength(1));
      expect(flow.generated.single, hasLength(1));
      expect(flow.generated.single.single['id'], parent);
      expect(flow.generated.single.single['body'], _question);
      expect(flow.sends.where((reply) => !isHoldingReply(reply)), [_formal]);
      expect(flow.sends.where(isHoldingReply), hasLength(holdingFirst ? 1 : 0));
      expect(await flow.query(tester, flow.db.unansweredWorkCounts), isEmpty);
      final actual = (flow.document['messages'] as List)
          .whereType<Map>()
          .where((message) =>
              message['direction'] == 'incoming' &&
              message['body'] == _question)
          .toList();
      expect(actual, hasLength(1));
      expect(actual.single['id'], parent);
      expect(tester.takeException(), isNull);
      await flow.close(tester);
    });
  }
}
