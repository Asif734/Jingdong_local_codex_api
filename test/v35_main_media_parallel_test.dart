import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

import 'helpers/run_permissions.dart';

void main() {
  testWidgets(
      'a suspended video acquisition cannot block another customer text reply',
      (tester) async {
    const a = 'jd_41aeec7741d05', b = 'jd_v35_second_customer';
    const channel = MethodChannel('v35.parallel.capture');
    const tinyPng =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=';
    late Directory root;
    late CaptureDatabase db;
    late File video;
    final cropGate = Completer<void>();
    final speechGate = Completer<void>();
    addTearDown(() {
      if (!speechGate.isCompleted) speechGate.complete();
    });
    var speechStarted = false;
    var cropStarted = false, secondArrived = false;
    var redA = true, redB = false;
    var active = a;
    final sent = <String>[];
    final generated = <String, List<List<Map<String, dynamic>>>>{};
    final frameTimes = <String, int>{};
    final manifests = <String, String>{};
    late Map<String, Object?> recorded;
    late String cover;
    await tester.runAsync(() async {
      recorded = Map<String, Object?>.from(jsonDecode(
          await File('test/fixtures/v38_media_parent/attendance-owned.ocr.json')
              .readAsString()) as Map);
      recorded['pngBase64'] = base64Encode(
          await File('test/fixtures/v38_media_parent/attendance-owned.png')
              .readAsBytes());
      cover = base64Encode(
          await File('test/fixtures/v35_media/unbound-video-cover.jpg')
              .readAsBytes());
      root = await Directory.systemTemp.createTemp('jd_v35_parallel_');
      db = CaptureDatabase(storageRoot: root);
      video = await File('test/fixtures/v35_media/unbound-video-original.mp4')
          .copy('${root.path}/verified-current-video.mp4');
    });
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
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
          return [
            {
              'customer': a,
              'identitySource': 'ax',
              'unread': redA,
              'unreadEvidence': redA ? 20 : 0,
              'redClockPresent': redA,
              'evidenceAvailable': true
            },
            if (secondArrived)
              {
                'customer': b,
                'identitySource': 'ax',
                'unread': redB,
                'unreadEvidence': redB ? 20 : 0,
                'redClockPresent': redB,
                'evidenceAvailable': true
              },
          ];
        case 'openConversation':
          active = args['expectedCustomer']! as String;
          return {'opened': true, 'customer': active};
        case 'captureViewportEvidence':
          final customer = args['expectedCustomer'] as String? ?? active;
          final id =
              customer == a ? 'recorded-unbound-video' : 'new-customer-text';
          frameTimes.putIfAbsent(
              id, () => DateTime.now().millisecondsSinceEpoch);
          final image = File('${root.path}/$id.png');
          if (!await image.exists()) {
            if (customer == a) {
              await File('test/fixtures/v38_media_parent/attendance-owned.png')
                  .copy(image.path);
            } else {
              await image.writeAsBytes(base64Decode(tinyPng));
            }
          }
          final manifest = File('${root.path}/$id.json');
          manifests[manifest.path] = customer;
          final metadata = <String, Object?>{
            'evidenceId': id,
            'customer': customer,
            'capturedAtMs': frameTimes[id],
            'windowId': 7,
            'automationSessionId': db.currentAutomationSessionId,
            'imagePath': image.path,
            'manifestPath': manifest.path,
            'chatRegion': {
              'left': .24027777777777778,
              'top': .20418204182041821,
              'right': .7479166666666667,
              'bottom': .7921279212792128
            },
            'chatContentSHA256': id,
          };
          await manifest.writeAsString(jsonEncode(metadata));
          return metadata;
        case 'inspectViewportEvidence':
          final customer = manifests[args['manifestPath']]!;
          if (customer == a) {
            return {
              ...recorded,
              'windowId': 7,
              'capturedAtMs': frameTimes['recorded-unbound-video']
            };
          }
          final time = DateTime.now().toUtc().add(const Duration(hours: 8));
          final clock =
              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
          return {
            'windowId': 7,
            'activeCustomerId': b,
            'pngBase64': tinyPng,
            'capturedAtMs': frameTimes['new-customer-text'],
            'imageWidth': 2880,
            'imageHeight': 1626,
            'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .79},
            'observations': [
              {
                'text': '$b $clock',
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
            'visualRegions': <Object>[]
          };
        case 'captureRecentCachedMedia':
          return {'kind': 'none'};
        case 'scrollConversation':
          if (args['deltaY'] == -10000) return {'scrolled': true};
          throw PlatformException(code: 'controlled_backfill_deferred');
        case 'cropViewportEvidence':
          expect(args['expectedCustomer'], a);
          cropStarted = true;
          await cropGate.future;
          return {
            'kind': 'video',
            'reason': 'pixel_matched_same_chat_video_companion',
            'captureSource': 'frozen-frame-video-cache',
            'playbackOverlayDetected': true,
            'visualFingerprint': '1234567890abcdef',
            'dataBase64': cover,
            'cardPreviewDataBase64': cover,
            'video': {
              'path': video.path,
              'originalName': 'unbound-video-original.mp4',
              'mimeType': 'video/mp4'
            }
          };
        case 'sendDraftOnce':
          final customer = args['expectedCustomer']! as String;
          expect(active, customer);
          sent.add(customer);
          if (customer == a) {
            redA = false;
          } else {
            redB = false;
          }
          return {
            'sent': true,
            'sendClickedAtMs': DateTime.now().millisecondsSinceEpoch
          };
        case 'transcribeAudio':
          speechStarted = true;
          await speechGate.future;
          return {
            'transcript': 'The printer is not feeding paper.',
            'language': 'en-US',
            'confidence': 1.0,
            'speechDetected': true
          };
      }
      return <String, Object?>{};
    });

    Future<void> tick({int steps = 1}) async {
      for (var i = 0; i < steps; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> until(bool Function() ready) async {
      for (var i = 0; i < 600 && !ready(); i++) {
        await tick();
      }
      expect(ready(), isTrue);
    }

    Future<T> query<T>(Future<T> Function() work) async {
      T? result;
      var complete = false;
      await tester.runAsync(() async {
        unawaited(work().then((value) {
          result = value;
          complete = true;
        }));
      });
      await until(() => complete);
      return result as T;
    }

    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
      database: db,
      adapter: MacOSCaptureAdapter(channel: channel),
      scanIntervalOverride: const Duration(milliseconds: 120),
      generateDraftOverride: (conversation, database, end, cancellation) async {
        final inputs = await database.generationMessages(conversation.userId,
            batchEndMessageId: end);
        generated.putIfAbsent(conversation.userId, () => []).add(inputs);
        return AiDraft.fromJson({
          'reply': 'Controlled reply for ${conversation.userId}.',
          'decision': 'draft',
          'confidence': 1.0,
          'risk_level': 'low',
          'model': 'controlled-v35',
          'auto_send_allowed': false,
          'actions': [],
          'attachments': [],
          'used_record_ids': []
        }, mediaBaseUrl: Uri());
      },
    )));
    await grantRunPermissions(tester);
    await tester.runAsync(() => tester.tap(find.text('Start automation')));
    await until(() => cropStarted);
    final before = (await query(() => db.processingMessages(a)))
        .where((message) => message['media_receipt_id'] != null)
        .toList();
    expect(before, hasLength(1),
        reason: 'The verified full incoming header admits exactly one durable '
            'video parent before its crop can complete');
    expect(
        await query(() => MediaCaptureAudit(db).pendingUnboundForCustomer(a)),
        isEmpty,
        reason: 'This fixture now has exact sender-block ownership; it must '
            'not be represented as an unbound cache-derived message');
    secondArrived = true;
    redB = true;
    active = b;
    await until(() => sent.contains(b));
    expect(cropGate.isCompleted, isFalse,
        reason:
            'Another customer was actually sent while the media future was pending');
    expect(
        (generated[b]!.single.where((m) => m['direction'] == 'incoming'))
            .single['body'],
        'How do I connect USB?');
    expect(await query(() => db.hasPendingUnanswered(b)), isFalse);
    cropGate.complete();
    await until(() => speechStarted);
    expect(
        (generated[a] ?? [])
            .expand((batch) => batch)
            .any((message) => message['media_receipt_id'] != null),
        isFalse,
        reason: 'The independent receipt question may answer, but the video '
            'cannot enter generation before speech finishes');
    final waitingVideo = (await query(() => db.processingMessages(a)))
        .singleWhere((message) => message['media_receipt_id'] != null);
    expect(
        await query(() =>
            db.isMessageFormallyAnswered(a, waitingVideo['id']! as String)),
        isFalse);
    expect(await query(() => db.hasPendingUnanswered(a)), isTrue);
    speechGate.complete();
    await until(() =>
        generated[a]?.any((batch) => batch.any((message) =>
            (message['media'] as List? ?? const []).whereType<Map>().any(
                (media) =>
                    media['capture_source'] == 'jd_video_cache' &&
                    media['path'] == video.path))) ==
        true);
    expect(
        await query(() => MediaCaptureAudit(db).pendingUnboundForCustomer(a)),
        isEmpty);
    final document = await query(() async => (await db.history).read(a));
    final received = (document!['messages'] as List)
        .whereType<Map>()
        .where((m) => (m['media'] as List? ?? const [])
            .whereType<Map>()
            .any((media) => media['capture_source'] == 'jd_video_cache'))
        .toList();
    expect(received, hasLength(1));
    final sender =
        DateTime.parse(received.single['sent_at']! as String).toUtc();
    expect([sender.hour, sender.minute, sender.second], [4, 21, 13],
        reason: 'The full incoming header supplies this original clock; cache '
            'download time and the other customer cannot replace it');
    final media = (received.single['media'] as List).whereType<Map>().toList();
    expect(media.any((m) => m['capture_source'] == 'jd_video_cover'), isTrue);
    expect(
        media.any((m) => m['original_name'] == 'video_frame_00s.jpg'), isTrue);
    expect(
        media.any((m) => m['original_name'] == 'video_frame_tail.jpg'), isTrue);
    expect(
        media.any((m) =>
            m['type'] == 'video' &&
            m['description'].toString().contains('printer is not feeding')),
        isTrue);
    var complete = false;
    for (var i = 0; i < 200 && !complete; i++) {
      complete = await query(() =>
          db.isMessageFormallyAnswered(a, received.single['id']! as String));
      if (!complete) await tick();
    }
    expect(complete, isTrue);
    expect(
        (generated[a] ?? []).where((batch) =>
            batch.any((message) => message['media_receipt_id'] != null)),
        hasLength(1));
    await tester.runAsync(() => tester.tap(find.text('Stop automation')));
    await tick(steps: 25);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isMacOS);
}
