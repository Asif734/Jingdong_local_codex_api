import 'helpers/run_permissions.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

void main() {
  for (final (late, chrome, video, withoutRectangle) in [
    (false, false, false, false),
    (true, false, false, false),
    (false, true, false, false),
    (false, false, true, false),
    (false, false, false, true),
  ]) {
    testWidgets(
        withoutRectangle
            ? 'a current pinned image without a detected rectangle keeps its original'
            : video
                ? 'video frames and history commit while speech is still pending'
                : chrome
                    ? 'seller chrome cannot cancel a pinned original in the production capture flow'
                    : late
                        ? 'late original is acquired even after screenshot ended unread recovery'
                        : 'real capture flow puts pinned cache original in history instead of window crop',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late CaptureDatabase db;
      final now = DateTime.now().toUtc();
      final china = now.add(const Duration(hours: 8));
      final clock =
          '${china.hour.toString().padLeft(2, '0')}:${china.minute.toString().padLeft(2, '0')}:${china.second.toString().padLeft(2, '0')}';
      const channel = MethodChannel('jd-original-media-regression');
      late Map<String, Object?> frameMetadata;
      var captureSerial = 0;
      var cacheAvailable = !late;
      var shuttingDown = false;
      var activeNativeCalls = 0;
      final calls = <String>[];
      final speech = Completer<Map<String, Object?>>();
      late List<int> originalBytes;
      await tester.runAsync(() async {
        originalBytes = await File('test/fixtures/v35_media/paper-image-1.png')
            .readAsBytes();
        root = await Directory.systemTemp.createTemp('jd_main_original_');
        db = CaptureDatabase(storageRoot: root);
        final frames =
            await Directory('${root.path}/capture_evidence').create();
        final png = File('${frames.path}/frame.png');
        await png.writeAsBytes(originalBytes);
        final original = File('${frames.path}/frame.original');
        await original.writeAsBytes(originalBytes);
        if (video) {
          final generated = await Process.run('/opt/homebrew/bin/ffmpeg', [
            '-hide_banner',
            '-loglevel',
            'error',
            '-f',
            'lavfi',
            '-i',
            'color=c=blue:s=160x120:r=10',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:sample_rate=16000',
            '-t',
            '2',
            '-c:v',
            'mpeg4',
            '-c:a',
            'aac',
            '-f',
            'mp4',
            '-y',
            original.path,
          ]);
          expect(generated.exitCode, 0, reason: '${generated.stderr}');
        }

        final manifest = File('${frames.path}/frame.json');
        final frame = ViewportEvidence({
          'evidenceId': 'frame',
          'customer': 'jd_test',
          'capturedAtMs': now.millisecondsSinceEpoch,
          'windowId': 7,
          'windowTitle': 'JD test reception',
          'windowBounds': {'x': 0.0, 'y': 0.0, 'width': 332.0, 'height': 252.0},
          'imageWidth': 332,
          'imageHeight': 252,
          'chatRegion': {'left': .2, 'right': .8, 'top': .25, 'bottom': .85},
          'pngSHA256': sha256.convert(originalBytes).toString(),
          'chatContentSHA256': sha256.convert(originalBytes).toString(),
          'imagePath': png.path,
          'manifestPath': manifest.path,
          if (!late)
            'pinnedMedia': {
              'kind': video ? 'video' : 'image',
              'path': original.path,
              'cacheKey': 'unique-original',
              'cacheModifiedAtMs': now.millisecondsSinceEpoch,
              'evidenceFile': original.path,
              'extension': 'png',
              'mimeType': video ? 'video/mp4' : 'image/png'
            }
        });
        frameMetadata = frame.metadata;
        await manifest.writeAsString(frame.toJson());
      });
      Future<Object?> native(MethodCall call) async {
        calls.add(call.method);
        if (shuttingDown && call.method == 'captureViewportEvidence') {
          throw PlatformException(code: 'automation_stopped');
        }
        switch (call.method) {
          case 'transcribeAudio':
            return speech.future;
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
                'customer': 'jd_test',
                'identitySource': 'ax',
                'unread': true,
                'redClockPresent': true,
                'unreadEvidence': 20,
                'unreadAgeSeconds': 0,
                'evidenceAvailable': true,
              }
            ];
          case 'openConversation':
            return {'opened': true, 'customer': 'jd_test'};
          case 'captureViewportEvidence':
            final args = Map<String, Object?>.from(call.arguments as Map);
            final id = 'frame-${++captureSerial}';
            final directory = Directory('${root.path}/capture_evidence');
            final image = await File(frameMetadata['imagePath']! as String)
                .copy('${directory.path}/$id.png');
            final manifest = File('${directory.path}/$id.json');
            final cutoff = args['historyCutoffMs'] ??
                (args['historyCutoffs'] as Map? ?? const {})['jd_test'];
            final captured = {
              ...frameMetadata,
              'evidenceId': id,
              'automationSessionId': args['automationSessionId'],
              'capturedAtMs': DateTime.now().millisecondsSinceEpoch,
              'imagePath': image.path,
              'manifestPath': manifest.path,
              if (cutoff != null) 'historyCutoffMs': cutoff,
            };
            await manifest.writeAsString(jsonEncode(captured));
            return captured;
          case 'inspectViewportEvidence':
            final args = Map<String, Object?>.from(call.arguments as Map);
            final captured = jsonDecode(
                    await File(args['manifestPath']! as String).readAsString())
                as Map;
            return {
              'evidenceId': captured['evidenceId'],
              'windowId': captured['windowId'],
              'imageWidth': captured['imageWidth'],
              'imageHeight': captured['imageHeight'],
              'pngBase64': base64Encode(
                  await File(captured['imagePath'] as String).readAsBytes()),
              'activeCustomerId': captured['customer'],
              'capturedAtMs': captured['capturedAtMs'],
              'chatRegion': captured['chatRegion'],
              'observations': [
                {
                  'text': 'jd_test $clock',
                  'confidence': 1.0,
                  'x': .24,
                  'y': .30,
                  'width': .2,
                  'height': .02
                },
                if (chrome) ...[
                  {
                    'text': '格志打印机小',
                    'confidence': 1.0,
                    'x': .5,
                    'y': .56,
                    'width': .18,
                    'height': .02
                  },
                  {
                    'text': '格志打印',
                    'confidence': 1.0,
                    'x': .5,
                    'y': .60,
                    'width': .12,
                    'height': .02
                  },
                ]
              ],
              'visualRegions': [
                if (!withoutRectangle)
                  {
                    'x': .24,
                    'y': .34,
                    'width': .2,
                    'height': .2,
                    'confidence': 1.0
                  }
              ]
            };
          case 'recentMediaCacheRevision':
            return {'revision': cacheAvailable ? 'original-ready' : 'pending'};
          case 'captureRecentCachedMedia':
            if (!cacheAvailable) return {'kind': 'none'};
            return {
              'kind': 'image',
              'cacheKey': 'late-original',
              'cacheModifiedAtMs': now.millisecondsSinceEpoch,
              'dataBase64': base64Encode(originalBytes),
              'extension': 'png',
              'mimeType': 'image/png',
              'captureSource': 'jd-image-cache'
            };
          case 'cropViewportEvidence':
            if (late) {
              return {
                'kind': 'image',
                'dataBase64': base64Encode(originalBytes),
                'extension': 'png',
                'captureSource': 'frozen-window-crop',
                'visualFingerprint': '0123'
              };
            }
            return {
              'kind': video ? 'video' : 'image',
              'captureSource': 'frozen-window-crop',
              'visualFingerprint': '0123'
            };
          case 'sendDraftOnce':
            fail(
                'No real or simulated customer sending is permitted in this capture regression');
        }
        return <String, Object?>{};
      }

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        activeNativeCalls++;
        try {
          return await native(call);
        } finally {
          activeNativeCalls--;
        }
      });
      await tester.pumpWidget(MaterialApp(
          home: CaptureHome(
              database: db,
              adapter: MacOSCaptureAdapter(channel: channel),
              mediaCacheProbeIntervalOverride:
                  late ? const Duration(milliseconds: 30) : null,
              draftSchedulerOverride: (_) {})));
      await grantRunPermissions(tester);
      // Start background file/SQL work in the real event loop. Awaiting a
      // serialized FakeAsync writer from runAsync otherwise deadlocks here.
      await tester.runAsync(() async {
        await tester.tap(find.text('Start automation'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      Map<String, dynamic>? document;
      Future<T> query<T>(Future<T> Function() work) async {
        T? result;
        Object? error;
        var complete = false;
        await tester.runAsync(() async {
          unawaited(work().then((value) {
            result = value;
            complete = true;
          }, onError: (Object failure) {
            error = failure;
            complete = true;
          }));
        });
        for (var i = 0; i < 300 && !complete; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
        expect(complete, isTrue,
            reason:
                'The database read must complete while FakeAsync can advance');
        if (error != null) throw error!;
        return result as T;
      }

      Future<void> awaitNativeIdle() async {
        for (var i = 0; i < 300 && activeNativeCalls != 0; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump();
        }
        expect(activeNativeCalls, 0,
            reason:
                'All entered native fixture calls must finish before deletion.');
      }

      Future<void> shutdown() async {
        // Block new screenshot-file creation before awaiting the real async
        // Stop callback. A tap alone does not await lease cancellation.
        shuttingDown = true;
        final dynamic stop = tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Stop automation'))
            .onPressed;
        await query(() async {
          await stop();
          return true;
        });
        await awaitNativeIdle();
        // These are ordering barriers, not a guessed delay: await the existing
        // customer's file writer and the already queued SQL transactions.
        final history = await query(() => db.history);
        await query(
            () => history.withCustomerSnapshot('jd_test', (_) async {}));
        await query(() async =>
            (await db.database).transaction((txn) => txn.rawQuery('SELECT 1')));
        await tester.pumpWidget(const SizedBox());
        await awaitNativeIdle();
        await query(
            () => history.withCustomerSnapshot('jd_test', (_) async {}));
        await query(() => db.close());
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await tester.runAsync(() => root.delete(recursive: true));
      }

      for (var i = 0; i < 200; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          // Read the atomically persisted file, not a serialization Future owned
          // by FakeAsync while runAsync has suspended that scheduler.
          final persisted = File('${root.path}/jd_test.json');
          if (await persisted.exists()) {
            document = jsonDecode(await persisted.readAsString())
                as Map<String, dynamic>;
          }
        });
        await tester.pump();
        if ((document?['messages'] as List? ?? const []).any(
            (m) => ((m as Map)['media'] as List? ?? const []).isNotEmpty)) {
          break;
        }
      }
      if (late) {
        cacheAvailable = true;
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 3100)));
        await tester.pump(const Duration(seconds: 3));
        for (var i = 0; i < 200; i++) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            // Read the atomically persisted file, not a serialization Future owned
            // by FakeAsync while runAsync has suspended that scheduler.
            final persisted = File('${root.path}/jd_test.json');
            if (await persisted.exists()) {
              document = jsonDecode(await persisted.readAsString())
                  as Map<String, dynamic>;
            }
          });
          await tester.pump();
          if ((document?['messages'] as List? ?? const []).any((m) => ((m
                  as Map)['media'] as List)
              .any((a) => (a as Map)['capture_source'] == 'jd_image_cache'))) {
            break;
          }
        }
      }
      Object? debugInbox;
      debugInbox = await query(() async => (await db.database).query(
          'capture_evidence',
          columns: ['state', 'attempts', 'last_error']));
      expect(document, isNotNull,
          reason:
              'Calls: $calls; inbox: $debugInbox; UI: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(" | ")}');
      final messages = document!['messages'] as List;

      if (video) {
        final stored =
            messages.expand((m) => (m as Map)['media'] as List).cast<Map>();
        expect(
            stored.where((m) => m['capture_source'] == 'jd_video_frame_1fps'),
            isNotEmpty,
            reason:
                'Visual frames must commit without waiting for speech. Calls: $calls');
        expect(speech.isCompleted, isFalse);
        for (var i = 0; i < 150 && !calls.contains('transcribeAudio'); i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump();
        }
        expect(calls, contains('transcribeAudio'));
        speech.complete({
          'transcript': 'Background test speech',
          'speechDetected': true,
          'language': 'en',
          'confidence': 1.0
        });
        for (var i = 0; i < 150; i++) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            // Read the atomically persisted file, not a serialization Future owned
            // by FakeAsync while runAsync has suspended that scheduler.
            final persisted = File('${root.path}/jd_test.json');
            if (await persisted.exists()) {
              document = jsonDecode(await persisted.readAsString())
                  as Map<String, dynamic>;
            }
          });
          await tester.pump();
          if (document.toString().contains('Background test speech')) break;
        }
        expect(document.toString(), contains('Background test speech'));
        await shutdown();
        return;
      }
      if (!late) expect(messages, hasLength(1));
      expect(
          messages
              .expand((m) => (m as Map)['media'] as List)
              .any((m) => (m as Map)['capture_source'] == 'jd_image_cache'),
          isTrue,
          reason: 'Original was not consumed. Native calls: $calls');
      final media = messages
          .expand((m) => (m as Map)['media'] as List)
          .whereType<Map>()
          .firstWhere((a) => a['capture_source'] == 'jd_image_cache');
      expect(media['capture_source'], 'jd_image_cache');
      expect(media['is_partial'], isFalse);
      await tester.runAsync(() async {
        expect(
            await File(media['path'] as String).readAsBytes(), originalBytes);
      });
      final owner = messages.whereType<Map>().firstWhere((message) =>
          (message['media'] as List? ?? const [])
              .whereType<Map>()
              .any((item) => item['path'] == media['path']));
      final evidenceId = owner['capture_evidence_id']! as String;
      var unresolved =
          await query(() => MediaCaptureAudit(db).unresolvedCount(evidenceId));
      for (var i = 0; i < 200 && unresolved > 0; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
        unresolved = await query(
            () => MediaCaptureAudit(db).unresolvedCount(evidenceId));
      }
      expect(unresolved, 0,
          reason:
              'A persisted verified original must finish its exact acquisition duty');
      if (chrome) {
        for (var i = 0; i < 50; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump();
          if (await query(() => db.hasPendingUnanswered('jd_test')) == true) {
            break;
          }
        }
        expect(await query(() => db.hasPendingUnanswered('jd_test')), isTrue);
        expect(await query(() => db.answeredMessageId('jd_test')), isNull);
        expect((await query(() => db.pendingSlaFallbackJobs())).single.userId,
            'jd_test');
      }
      await shutdown();
    }, skip: !Platform.isMacOS);
  }
}
