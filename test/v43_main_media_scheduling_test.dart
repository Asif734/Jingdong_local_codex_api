import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/red_clock_tracker.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';

import 'helpers/run_permissions.dart';

const _customer = 'jd_41aeec7741d05';
const _fixtures = 'test/fixtures/v42_recorded_video_identity';

// Real native frames pass through CaptureHome's actual admission, immutable
// OCR storage, media claim, full processing, generation and native receipt.
// An earlier unregistered OCR is deliberately suspended throughout that flow.

void main() {
  testWidgets(
      'admitted video starts before older OCR while another customer replies',
      (tester) async {
    const channel = MethodChannel('jd-v43-home-media-scheduling');
    const other = 'jd_v43_second_customer';
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
    var oldInserted = false;
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
      root = await Directory.systemTemp.createTemp('jd_v43_home_media_');
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
          if (name == 'gray-play' && !history && !oldInserted) {
            oldInserted = true;
            const oldId = 'home-gray-clipped';
            final oldImage = File('${directory.path}/$oldId.png');
            final oldManifest = File('${directory.path}/$oldId.json');
            await oldImage.writeAsBytes(imageBytes['gray-clipped']!);
            final oldSource = frames['gray-clipped']!;
            final old = <String, Object?>{
              ...metadata,
              'evidenceId': oldId,
              'capturedAtMs': stamp - 1,
              'imagePath': oldImage.path,
              'manifestPath': oldManifest.path,
              'pngSHA256':
                  sha256.convert(imageBytes['gray-clipped']!).toString(),
              'chatContentSHA256': 'recorded-gray-clipped',
              'recordedEvidenceId': oldSource['evidenceId'],
              'replyActivationAllowed': true,
              'capturePurpose': 'durable_unanswered',
            };
            await oldManifest.writeAsString(jsonEncode(old));
            manifests[oldManifest.path] = 'gray-clipped';
            at[oldId] = stamp - 1;
            // A retained older OCR retry is already ahead in chronological
            // order. It has no arrival proof or registered media parent.
            await (await db.database).insert('capture_evidence', {
              'id': oldId,
              'customer': _customer,
              'captured_at_ms': stamp - 1,
              'payload': ViewportEvidence(old).toJson(),
              'state': 'retry',
              'retry_at_ms': DateTime.now()
                  .add(const Duration(minutes: 1))
                  .millisecondsSinceEpoch,
              'discovery_requires_baseline': 0,
            });
          }
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
          if (phase == 'baseline' || args['expectedCustomer'] != _customer) {
            return {'kind': 'none'};
          }
          return {
            'kind': 'video',
            'cacheKey': 'v43-recorded-original',
            'cacheModifiedAtMs': DateTime.now().millisecondsSinceEpoch,
            'path': video,
            'originalName': 'native-complete-video.mp4',
            'mimeType': 'video/mp4',
          };
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
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    Future<void> until(bool Function() ready, {int steps = 3000}) async {
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
    await waitWork(1);
    final parent = (await work()).single['message_id'];
    expect(oldInserted, isTrue);
    await query(() async => (await db.database).update(
        'capture_evidence', {'state': 'captured', 'retry_at_ms': 0},
        where: 'id=?', whereArgs: ['home-gray-clipped']));
    await until(() => oldOcrStarted);
    await until(() => cropStarted);
    expect(releaseOldOcr.isCompleted, isFalse,
        reason:
            'The admitted video starts while older OCR is still suspended.');
    final oldWhileMediaStarts = await query(() async => (await db.database)
        .query('capture_evidence',
            where: 'id=?', whereArgs: ['home-gray-clipped']));
    expect(oldWhileMediaStarts.single['state'], 'processing');
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
    expect(oldOcrStarted, isTrue);
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
