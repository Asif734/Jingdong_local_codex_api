import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'helpers/run_permissions.dart';

void main() {
  for (final (partial, outsideWindow) in [
    (false, false),
    (true, false),
    (false, true)
  ]) {
    testWidgets(
        outsideWindow
            ? 'an older owned video still acquires its verified original without promoting the JPG cover'
            : partial
                ? 'an admitted video survives later clipping and 好的 without changing its own clock'
                : 'frozen positive video overrides a pinned jpg and preserves its overlapping own header clock',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000,
          isUtc: true);
      final videoAt = now.subtract(const Duration(seconds: 10));
      String clock(DateTime at) {
        final local = at.add(const Duration(hours: 8));
        return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
      }

      late Directory root;
      late CaptureDatabase db;
      late Map<String, Object?> frameMetadata;
      DateTime? liveCaptureAt;
      var captureSerial = 0;
      var clipped = false;
      var inspectedClipped = false;
      late File original;
      late List<int> previewBytes;
      final calls = <String>[];
      await tester.runAsync(() async {
        previewBytes =
            await File('test/fixtures/v30_media/upper-play-video.png')
                .readAsBytes();
        root = await Directory.systemTemp.createTemp('v30_capture_video_');
        db = CaptureDatabase(storageRoot: root);
        final directory =
            await Directory('${root.path}/capture_evidence').create();
        original = File('${directory.path}/owned-original.mp4');
        final generated = await Process.run('/opt/homebrew/bin/ffmpeg', [
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'lavfi',
          '-i',
          'color=c=blue:s=160x120:r=10',
          '-t',
          '1',
          '-c:v',
          'mpeg4',
          '-an',
          '-y',
          original.path
        ]);
        expect(generated.exitCode, 0, reason: '${generated.stderr}');
        final poster = await File('${directory.path}/cover.jpg')
            .writeAsBytes(previewBytes);
        final image =
            await File('${directory.path}/frame.png').writeAsBytes([1]);
        final manifest = File('${directory.path}/frame.json');
        final evidence = ViewportEvidence({
          'evidenceId': 'frame',
          'customer': 'jd_v30_customer',
          'capturedAtMs': now.millisecondsSinceEpoch,
          'imagePath': image.path,
          'manifestPath': manifest.path,
          'pinnedMedia': {
            'kind': partial ? 'video' : 'image',
            'path': partial ? original.path : poster.path,
            'cacheKey': 'owned-pinned-cache',
            'cacheModifiedAtMs': videoAt.millisecondsSinceEpoch,
            'evidenceFile': partial ? original.path : poster.path,
            'extension': partial ? 'mp4' : 'jpg',
            'mimeType': partial ? 'video/mp4' : 'image/jpeg'
          }
        });
        frameMetadata = evidence.metadata;
        await manifest.writeAsString(evidence.toJson());
      });
      final channel = MethodChannel('v30.media.capture.$partial');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
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
                'customer': 'jd_v30_customer',
                'identitySource': 'ax',
                'unread': true,
                'redClockPresent': true,
                'unreadEvidence': 20,
                'unreadAgeSeconds': outsideWindow ? 0 : 10,
                'evidenceAvailable': true,
              }
            ];
          case 'openConversation':
            return {'opened': true, 'customer': 'jd_v30_customer'};
          case 'captureViewportEvidence':
            liveCaptureAt = DateTime.now().toUtc();
            frameMetadata = {
              ...frameMetadata,
              'evidenceId': 'frame-${++captureSerial}',
              'capturedAtMs': liveCaptureAt!.millisecondsSinceEpoch
            };
            return frameMetadata;
          case 'captureRecentCachedMedia':
            return {'kind': 'none'};
          case 'transcribeAudio':
            return {
              'speechDetected': false,
              'reason': 'synthetic_silent_video'
            };
          case 'inspectViewportEvidence':
            if (clipped) inspectedClipped = true;
            return {
              'windowId': 7,
              'imageWidth': 2880,
              'imageHeight': 1626,
              'pngBase64':
                  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=',
              'activeCustomerId': 'jd_v30_customer',
              'capturedAtMs': (liveCaptureAt ?? now).millisecondsSinceEpoch,
              'chatRegion': {
                'left': .24027777777777778,
                'right': .7479166666666667,
                'top': .20418204182041821,
                'bottom': .8044280442804428
              },
              'observations': partial && clipped
                  ? [
                      {
                        'text': 'jd_v30_customer ${clock(now)}',
                        'confidence': 1.0,
                        'x': .2747,
                        'y': .6605166,
                        'width': .16,
                        'height': .018
                      },
                      {
                        'text': '好的',
                        'confidence': 1.0,
                        'x': .279,
                        'y': .69665,
                        'width': .022,
                        'height': .023
                      }
                    ]
                  : [
                      {
                        'text':
                            'jd_v30_customer ${clock(videoAt.subtract(const Duration(seconds: 10)))}',
                        'confidence': 1.0,
                        'x': .2747,
                        'y': .2724477,
                        'width': .16,
                        'height': .018
                      },
                      {
                        'text': 'Please inspect this',
                        'confidence': 1.0,
                        'x': .28,
                        'y': .31,
                        'width': .15,
                        'height': .018
                      },
                      {
                        'text': 'jd_v30_customer ${clock(videoAt)}',
                        'confidence': 1.0,
                        'x': .2747,
                        'y': .36503856,
                        'width': .16,
                        'height': .01811027
                      },
                    ],
              'visualRegions': [
                {
                  'x': .26697099,
                  'y': partial && clipped ? .22904598 : .37639349,
                  'width': .12160047,
                  'height': partial && clipped ? .16165548 : .2719424,
                  'confidence': 1.0
                }
              ]
            };
          case 'cropViewportEvidence':
            return {
              'kind': 'video',
              'reason': 'pixel_matched_same_chat_video_companion',
              'captureSource': 'frozen-frame-video-cache',
              'visualFingerprint': '1234567890abcdef',
              'cacheKey': 'owned-crop-video',
              'cacheModifiedAtMs': videoAt.millisecondsSinceEpoch,
              'video': {
                'path': original.path,
                'originalName': 'owned-original.mp4',
                'mimeType': 'video/mp4'
              },
              'dataBase64': 'CQgH',
              'cardPreviewDataBase64': base64Encode(previewBytes),
              'playbackOverlayDetected': true
            };
          case 'sendDraftOnce':
            fail('Capture regressions never send a real or simulated reply');
        }
        return <String, Object?>{};
      });
      await tester.pumpWidget(MaterialApp(
          home: CaptureHome(
              database: db,
              adapter: MacOSCaptureAdapter(channel: channel),
              draftSchedulerOverride: (_) {})));
      await grantRunPermissions(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Start automation'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      Map<String, dynamic>? document;
      for (var i = 0; i < 300; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final file = File('${root.path}/jd_v30_customer.json');
          if (await file.exists()) {
            document =
                jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          }
        });
        await tester.pump();
        if ((document?['messages'] as List? ?? const []).any((m) =>
            (m['media'] as List? ?? const [])
                .any((a) => a['capture_source'] == 'jd_video_frame_1fps'))) {
          break;
        }
      }
      final videoMessages = (document?['messages'] as List? ?? const [])
          .where((m) => (m['media'] as List? ?? const [])
              .any((a) => a['capture_source'] == 'jd_video_frame_1fps'))
          .toList();
      expect(videoMessages, isNotEmpty,
          reason:
              'Receipt ownership must survive any delay. Calls: $calls; saved: $document; metadata: $frameMetadata');
      final message = videoMessages.single;
      expect(message['body'], contains('Customer sent a video'));
      if (partial) {
        final admittedId = message['id'];
        final receivedAt = message['captured_at'];
        clipped = true;
        for (var i = 0; i < 180; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            document = jsonDecode(
                await File('${root.path}/jd_v30_customer.json')
                    .readAsString()) as Map<String, dynamic>;
          });
          if (inspectedClipped &&
              (document!['messages'] as List).any((m) => m['body'] == '好的')) {
            break;
          }
        }
        expect(inspectedClipped, isTrue);
        final owned = (document!['messages'] as List).where((m) =>
            (m['media'] as List? ?? const [])
                .any((a) => a['capture_source'] == 'jd_video_frame_1fps'));
        expect(owned, hasLength(1));
        expect(owned.single['id'], admittedId);
        expect(owned.single['captured_at'], receivedAt);
        expect(
            DateTime.parse(owned.single['sent_at']! as String).toUtc(), videoAt,
            reason: 'The later text cannot retime the existing video parent.');
      } else {
        expect(DateTime.parse(message['sent_at']! as String).toUtc(), videoAt);
        final media =
            (document!['messages'] as List).expand((m) => m['media'] as List);
        expect(media.where((m) => m['capture_source'] == 'jd_image_cache'),
            isEmpty,
            reason: 'A cached JPG cover cannot become a separate image input');
        expect(calls, contains('cropViewportEvidence'));
      }
      await tester.tap(find.text('Stop automation'));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      if (!partial) {
        await tester.runAsync(() async {
          final rows = await (await db.database)
              .query('media_card_observations', columns: ['preview_path']);
          final paths =
              rows.map((r) => r['preview_path']).whereType<String>().toList();
          expect(paths, isNotEmpty);
          expect(await File(paths.first).readAsBytes(), previewBytes,
              reason:
                  'The owned card preview must persist even when its sender clock is older than the unread signal');
        });
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
