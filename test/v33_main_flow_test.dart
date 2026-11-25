import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/live_message_activation.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'helpers/run_permissions.dart';

void main() {
  const pngBase64 =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=';
  final now = DateTime.utc(2026, 11, 5, 10);
  CapturedMessage input(String id, Duration age) => CapturedMessage(
      stableId: id,
      direction: 'incoming',
      body: 'Unanswered question $id',
      sentAt: now.subtract(age),
      axPath: id);
  final delayed = CapturedConversation(
      stableKey: 'jd',
      customerName: 'jd',
      capturedAt: now,
      messages: [
        input('older-question', const Duration(minutes: 4)),
        CapturedMessage(
            stableId: 'unrelated-seller-reply',
            direction: 'outgoing',
            body: 'Answer to another question',
            sentAt: now.subtract(const Duration(minutes: 1)),
            axPath: 'outgoing'),
        input('newer-question', const Duration(seconds: 30)),
      ]);

  test('live unanswered inputs survive old clocks and intervening seller text',
      () {
    expect(
        activeLiveIncomingIds(delayed,
            replyActivationAllowed: true,
            signalAt: now,
            knownIncomingIds: {'older-question'}),
        {'older-question', 'newer-question'});
  });
  test('requested current backfill activates inputs; history-only does not',
      () {
    expect(
        activeLiveIncomingIds(delayed,
            replyActivationAllowed: true, historyCutoff: now, signalAt: now),
        {'older-question', 'newer-question'});
    expect(
        activeLiveIncomingIds(delayed,
            replyActivationAllowed: false, historyCutoff: now, signalAt: now),
        isEmpty);
  });

  for (final mode in [
    'unverified',
    'video',
    'crop_failure',
    'busy_acquisition',
    'two_same_second',
    'continuous_inputs'
  ]) {
    testWidgets('$mode owned card becomes durable unanswered media work',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late CaptureDatabase db;
      late File image;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('v33_pending_media_');
        db = CaptureDatabase(storageRoot: root);
        await db.database;
        await db.history;
        image = await File('${root.path}/source.png')
            .writeAsBytes(base64Decode(pngBase64));
      });
      final channel = MethodChannel('v33.main.$mode');
      var serial = 0;
      final senderBase = DateTime.now()
          .toUtc()
          .add(const Duration(hours: 8))
          .subtract(const Duration(minutes: 3));
      var crops = 0;
      var sends = 0;
      final scheduled = <String>[];
      final busy = mode == 'busy_acquisition';
      final continuous = mode == 'continuous_inputs';
      final twoCards = mode == 'two_same_second';
      final blockedModel = busy || continuous;
      var cancelled = 0;
      final cropGate = Completer<void>();
      var generations = 0;
      var live = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
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
                'customer': 'jd_v33_customer',
                'identitySource': 'ax',
                'unread': live,
                'unreadEvidence': 20,
                'redClockPresent': live,
                'unreadAgeSeconds': 0,
                'evidenceAvailable': true
              }
            ];
          case 'openConversation':
            return {'opened': true, 'customer': 'jd_v33_customer'};
          case 'captureViewportEvidence':
            final sequence = ++serial;
            final manifest = await File('${root.path}/frame-$sequence.json')
                .writeAsString('{}');
            return {
              'evidenceId': 'frame-$sequence',
              'customer': 'jd_v33_customer',
              'imagePath': image.path,
              'manifestPath': manifest.path,
              'capturedAtMs': DateTime.now().millisecondsSinceEpoch,
            };
          case 'captureRecentCachedMedia':
            return {'kind': 'none'};
          case 'inspectViewportEvidence':
            final args = call.arguments as Map;
            final sequence = int.parse(RegExp(r'frame-(\d+)\.json$')
                .firstMatch(args['manifestPath']! as String)!
                .group(1)!);
            final senderAt =
                senderBase.add(Duration(seconds: continuous ? sequence : 1));
            final clock = senderAt.toIso8601String().substring(11, 19);
            return {
              'windowId': 7,
              'pngBase64': pngBase64,
              'activeCustomerId': 'jd_v33_customer',
              'imageWidth': 2880,
              'imageHeight': 1626,
              'capturedAtMs': DateTime.now().millisecondsSinceEpoch,
              'chatRegion': {
                'left': .24,
                'right': .75,
                'top': .20,
                'bottom': .81
              },
              'observations': !live
                  ? []
                  : [
                      if (busy) ...[
                        {
                          'text':
                              'jd_v33_customer ${senderAt.subtract(const Duration(seconds: 1)).toIso8601String().substring(11, 19)}',
                          'confidence': 1.0,
                          'x': .2747,
                          'y': .275,
                          'width': .18,
                          'height': .018,
                        },
                        {
                          'text': 'What is the warranty period?',
                          'confidence': 1.0,
                          'x': .275,
                          'y': .31,
                          'width': .3,
                          'height': .02,
                        },
                        {
                          'text':
                              '格志打印机小耿 ${senderAt.toIso8601String().substring(11, 19)}',
                          'confidence': 1.0,
                          'x': .51,
                          'y': .341,
                          'width': .2,
                          'height': .018,
                        },
                      ],
                      {
                        'text': 'jd_v33_customer $clock',
                        'confidence': 1.0,
                        'x': .2747,
                        'y': .365,
                        'width': .18,
                        'height': .018,
                      },
                      if (busy) ...[
                        {
                          'text': 'VIDEO SUBTITLE IS MEDIA CONTENT',
                          'confidence': 1.0,
                          'x': .275,
                          'y': .44,
                          'width': .105,
                          'height': .03,
                        },
                        {
                          'text': 'PRINTED INSIDE THE VIDEO CARD',
                          'confidence': 1.0,
                          'x': .275,
                          'y': .49,
                          'width': .105,
                          'height': .03,
                        },
                      ],
                      if (continuous)
                        {
                          'text':
                              'Question $sequence: does the warranty include part $sequence?',
                          'confidence': 1.0,
                          'x': .275,
                          'y': .40,
                          'width': .3,
                          'height': .02,
                        },
                      if (twoCards)
                        {
                          'text': 'jd_v33_customer $clock',
                          'confidence': 1.0,
                          'x': .2747,
                          'y': .635,
                          'width': .18,
                          'height': .018,
                        },
                    ],
              'visualRegions': !live || continuous
                  ? []
                  : [
                      {
                        'x': .267,
                        'y': .397,
                        'width': .122,
                        'height': twoCards ? .20 : .25,
                        'confidence': 1.0,
                      },
                      if (twoCards)
                        {
                          'x': .267,
                          'y': .67,
                          'width': .122,
                          'height': .12,
                          'confidence': 1.0,
                        }
                    ],
            };
          case 'cropViewportEvidence':
            crops++;
            if (busy) await cropGate.future;
            if (mode == 'crop_failure') {
              throw PlatformException(code: 'image_crop_verification_failed');
            }
            return {
              'kind': busy || twoCards ? 'unverified' : mode,
              'reason': 'original_unavailable',
              'visualFingerprint': '0000000000000000',
              'foregroundFraction': 0.0,
              'playbackOverlayDetected': mode == 'video',
            };
          case 'sendDraftOnce':
            sends++;
            fail('This regression only captures evidence');
        }
        return <String, Object?>{};
      });
      await tester.pumpWidget(MaterialApp(
          home: CaptureHome(
              database: db,
              adapter: MacOSCaptureAdapter(channel: channel),
              scanIntervalOverride:
                  continuous ? const Duration(milliseconds: 120) : null,
              draftSchedulerOverride: blockedModel ? null : scheduled.add,
              generateDraftOverride: blockedModel
                  ? (_, __, ___, cancellation) {
                      generations++;
                      final result = Completer<AiDraft>();
                      cancellation.addListener(() {
                        cancelled++;
                        result.completeError(const CodexGenerationCancelled());
                      });
                      return result.future;
                    }
                  : null)));
      await grantRunPermissions(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Start automation'));
      });
      // Start first observes an empty conversation. The later AX transition
      // and incoming card are this run's real arrival, not old startup work.
      var baselineReady = false;
      for (var i = 0; i < 150; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          baselineReady = (await (await db.database).query(
                  'capture_discovery_state',
                  where: "customer=? AND kind='baseline' AND ready=1",
                  whereArgs: ['jd_v33_customer']))
              .isNotEmpty;
        });
        await tester.pump(const Duration(milliseconds: 200));
        if (baselineReady) break;
      }
      expect(baselineReady, isTrue);
      live = true;
      Map<String, dynamic>? document;
      var pending = false;
      for (var i = 0; i < 150; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final file = File('${root.path}/jd_v33_customer.json');
          if (await file.exists()) {
            document =
                jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          }
          // Both callbacks run only after the app's own durable pending check.
          // Do not await a fake-zone SQLite query from runAsync while polling.
          pending = scheduled.isNotEmpty || generations > 0;
        });
        await tester.pump(const Duration(milliseconds: 20));
        if (pending &&
            (continuous || busy || crops > 0) &&
            (continuous
                ? generations > 0 && serial >= 14
                : busy
                    ? generations > 0
                    : scheduled.isNotEmpty)) {
          break;
        }
      }
      final messages = (document?['messages'] as List? ?? const [])
          .whereType<Map>()
          .where((m) => m['direction'] == 'incoming')
          .toList();
      if (!continuous) {
        expect(crops, greaterThan(0));
      }
      expect(messages, isNotEmpty,
          reason: 'An unavailable original cannot erase the customer input');
      if (continuous) {
        expect(messages.length, greaterThan(3));
        expect(generations, 1,
            reason: 'Continuous inputs must not reset the first batch timer');
        expect(cancelled, 0,
            reason: 'A frozen business scope must survive later customer text');
      } else if (busy) {
        expect(cropGate.isCompleted, isFalse);
        expect(messages.any((m) => m['body'] == 'What is the warranty period?'),
            isTrue,
            reason:
                'The actual same-frame OCR question must be saved before crop completes');
        expect(
            messages.firstWhere((m) =>
                m['body'] ==
                'What is the warranty period?')['capture_evidence_id'],
            startsWith('frame-'),
            reason:
                'The frozen question must retain exact same-frame media provenance');
        expect(messages.any((m) => m['body'].toString().contains('SUBTITLE')),
            isFalse,
            reason:
                'Dense text inside an unclassified media card is not customer prose');
        expect(generations, 1,
            reason:
                'Continuous optional acquisition cannot starve a durable question');
      } else {
        expect(messages.first['id'], startsWith('incoming-media:'));
        expect(messages.first['body'],
            '[Customer sent media; acquisition pending.]');
        if (twoCards) {
          expect(messages, hasLength(2),
              reason: 'Two simultaneously visible cards are two arrivals, even '
                  'with identical sender seconds and identical mock pixels');
          expect(messages.map((m) => m['id']).toSet(), hasLength(2));
          expect(messages.map((m) => m['sent_at']).toSet(), hasLength(1));
        }
        expect(messages.first['media'], isEmpty,
            reason:
                'Pending is a receipt, never a fabricated image/video file');
        expect(scheduled, contains('jd_v33_customer'));
      }
      expect(pending, isTrue);
      expect(sends, 0);
      await tester.tap(find.text('Stop automation'));
      if (!cropGate.isCompleted) cropGate.complete();
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }, skip: !Platform.isMacOS);
  }
}
