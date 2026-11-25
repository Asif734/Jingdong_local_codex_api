import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

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
import 'package:jd_automation/storage/capture_evidence_store.dart';

import 'helpers/run_permissions.dart';

const _customer = 'jd_41aeec7741d05';
const _other = 'jd_v45_other_customer';
const _fixtures = 'test/fixtures/v45_recorded_image_admission';

void main() {
  testWidgets(
      'CaptureHome recovers actual two same-file image sends through loading and another customer',
      (tester) async {
    const channel = MethodChannel('v45-home-real-image-recovery');
    late Directory root;
    late CaptureDatabase db;
    final ocr = <String, Map<String, Object?>>{};
    final png = <String, List<int>>{};
    final meta = <String, Map<String, Object?>>{};
    final snapshots = <String, Map<String, Object?>>{};
    final names = <String, String>{};
    final observed = <String, int>{};
    final cropped = <String>[];
    final calls = <String>[];
    final formal = <String>[];
    final generations = <List<Map<String, dynamic>>>[];
    final cropGate = Completer<void>();
    final analysisGate = Completer<void>();
    final lateOcrGate = Completer<void>();
    var phase = 'baseline';
    var active = _customer;
    var otherArrived = false;
    var otherAnswered = false;
    var aFormal = false;
    var aGenerationStarted = false;
    var lateOcrStarted = false;
    var lateOcrCompleted = false;
    var monotonic = 0;
    late List<int> original;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_v45_home_images_');
      db = CaptureDatabase(storageRoot: root);
      final provenance =
          jsonDecode(await File('$_fixtures/provenance.json').readAsString())
              as Map;
      for (final name in [
        'first',
        'first-late',
        'second-loading',
        'second-loaded'
      ]) {
        png[name] = await File('$_fixtures/$name.png').readAsBytes();
        final raw = await File('$_fixtures/$name.ocr.json').readAsBytes();
        expect(sha256.convert(png[name]!).toString(),
            provenance['frames'][name]['pngSHA256']);
        expect(sha256.convert(raw).toString(),
            provenance['frames'][name]['ocrSHA256']);
        ocr[name] =
            Map<String, Object?>.from(jsonDecode(utf8.decode(raw)) as Map);
        meta[name] = Map<String, Object?>.from(jsonDecode(
            await File('$_fixtures/$name.capture.json').readAsString()) as Map);
      }
      original = await File('$_fixtures/first.original').readAsBytes();
      final resent =
          await File('$_fixtures/second-loading.original').readAsBytes();
      expect(sha256.convert(original).toString(),
          provenance['frames']['first']['originalSHA256']);
      expect(sha256.convert(resent), sha256.convert(original),
          reason: 'The two real separately sent screenshots reuse one asset.');
      const baseline = 'test/fixtures/v42_recorded_video_identity/baseline';
      png['baseline'] = await File('$baseline.png').readAsBytes();
      ocr['baseline'] = Map<String, Object?>.from(
          jsonDecode(await File('$baseline.ocr.json').readAsString()) as Map);
      // Recorded clock-only headers must move with today's capture metadata.
      // Otherwise a fixed morning baseline can parse as today while a fixed
      // afternoon image parses as yesterday, depending on wall-clock time.
      // Compress only fixture time: order and repeated-bubble clocks stay exact;
      // all PNG/OCR source checksums above still validate the original evidence.
      final clockPattern =
          RegExp(r'(?<!\d)(\d{1,2})[:：](\d{2})[:：](\d{2})(?!\d)');
      DateTime second(DateTime at) => DateTime.utc(
          at.year, at.month, at.day, at.hour, at.minute, at.second);
      final originalTimes = <DateTime>{};
      DateTime originalHeader(Map source, Match match) {
        final capture = DateTime.fromMillisecondsSinceEpoch(
                source['capturedAtMs']! as int,
                isUtc: true)
            .add(const Duration(hours: 8));
        return DateTime.utc(
                capture.year,
                capture.month,
                capture.day,
                int.parse(match[1]!),
                int.parse(match[2]!),
                int.parse(match[3]!))
            .subtract(const Duration(hours: 8));
      }

      bool sender(Map line) => RegExp(r'jd_41aeec7741d05|格志打印机|旗舰店|其他客服')
          .hasMatch(line['text']?.toString() ?? '');
      for (final source in ocr.values) {
        for (final line
            in (source['observations'] as List).cast<Map>().where(sender)) {
          for (final match in clockPattern.allMatches(line['text'] as String)) {
            originalTimes.add(originalHeader(source, match));
          }
        }
      }
      void collect(Object? value, {String? key}) {
        if (value is Map) {
          for (final entry in value.entries) {
            collect(entry.value, key: '${entry.key}');
          }
        } else if (value is List) {
          for (final item in value) {
            collect(item);
          }
        } else if (key == 'sent_at' && value is String) {
          final at = DateTime.tryParse(value);
          if (at != null) originalTimes.add(second(at.toUtc()));
        } else if (const {'mediaCoverageCutoffMs', 'cacheModifiedAtMs'}
                .contains(key) &&
            value is int) {
          originalTimes.add(
              second(DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)));
        }
      }

      for (final source in meta.values) {
        collect(source);
      }
      final timeline = originalTimes.toList()..sort();
      final firstSender = DateTime.utc(2026, 11, 9, 9, 7, 57);
      expect(timeline, contains(firstSender));
      final base = second(DateTime.now().toUtc())
          .subtract(Duration(seconds: timeline.indexOf(firstSender) - 1));
      DateTime mapped(DateTime source) {
        final at = source.toUtc();
        final index = timeline.indexOf(second(at));
        expect(index, isNonNegative,
            reason: 'Every fixture time has an explicit mapping.');
        return base.add(Duration(
            seconds: index,
            milliseconds: at.millisecond,
            microseconds: at.microsecond));
      }

      for (final source in ocr.values) {
        source['observations'] = [
          for (final line in (source['observations'] as List).cast<Map>())
            {
              ...line,
              if (sender(line))
                'text': (line['text'] as String).replaceAllMapped(clockPattern,
                    (match) {
                  final jd = mapped(originalHeader(source, match))
                      .add(const Duration(hours: 8));
                  return '${jd.hour.toString().padLeft(2, '0')}:'
                      '${jd.minute.toString().padLeft(2, '0')}:'
                      '${jd.second.toString().padLeft(2, '0')}';
                })
            }
        ];
      }
      Object? mapMetadata(Object? value, {String? key}) {
        if (value is Map) {
          return {
            for (final entry in value.entries)
              entry.key: mapMetadata(entry.value, key: '${entry.key}')
          };
        }
        if (value is List) return [for (final item in value) mapMetadata(item)];
        if (key == 'sent_at' && value is String) {
          final at = DateTime.tryParse(value);
          if (at != null) return mapped(at).toIso8601String();
        }
        if (const {'mediaCoverageCutoffMs', 'cacheModifiedAtMs'}
                .contains(key) &&
            value is int) {
          return mapped(DateTime.fromMillisecondsSinceEpoch(value, isUtc: true))
              .millisecondsSinceEpoch;
        }
        return value;
      }

      for (final name in meta.keys.toList()) {
        meta[name] = Map<String, Object?>.from(mapMetadata(meta[name])! as Map);
      }
      final now = DateTime.now().toUtc().add(const Duration(hours: 8));
      final clock = '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}:'
          '${now.second.toString().padLeft(2, '0')}';
      ocr['other'] = {
        'activeCustomerId': _other,
        'windowId': 17539,
        'imageWidth': 2880,
        'imageHeight': 1626,
        'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .79},
        'observations': [
          {
            'text': '$_other $clock',
            'confidence': 1.0,
            'x': .27,
            'y': .30,
            'width': .25,
            'height': .02
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
      png['other'] = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=');
    });
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      if (!cropGate.isCompleted) cropGate.complete();
      if (!analysisGate.isCompleted) analysisGate.complete();
      if (!lateOcrGate.isCompleted) lateOcrGate.complete();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await db.close();
        if (await root.exists()) await root.delete(recursive: true);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<Map<String, Object?>> snapshot(String name) async {
      final id = 'v45-home-$name';
      if (snapshots[id] case final existing?) return existing;
      final directory =
          await Directory('${root.path}/capture_evidence').create();
      final image =
          await File('${directory.path}/$id.png').writeAsBytes(png[name]!);
      final manifest = File('${directory.path}/$id.json');
      final source = ocr[name]!;
      final values = <String, Object?>{
        ...?meta[name],
        'evidenceId': id,
        'automationSessionId': db.currentAutomationSessionId,
        'automationSessionStartedAtMs':
            db.automationSessionStartedAt?.millisecondsSinceEpoch,
        'customer': name == 'other' ? _other : _customer,
        'capturedAtMs': name == 'first-late'
            ? (snapshots['v45-home-first']!['capturedAtMs']! as int) + 1
            : DateTime.now().millisecondsSinceEpoch,
        'windowId': source['windowId'],
        'imageWidth': source['imageWidth'],
        'imageHeight': source['imageHeight'],
        'chatRegion': source['chatRegion'],
        'imagePath': image.path,
        'manifestPath': manifest.path,
        'pngSHA256': sha256.convert(png[name]!).toString(),
        'chatContentSHA256': 'actual-v44-$name',
      };
      // Preserve the actual white frame's absent AX proof. It is retained in
      // the inbox directly, then admitted only when loaded-frame AX arrives.
      if (name == 'second-loading') {
        values.remove('unreadArrivalKey');
        values['replyActivationAllowed'] = true;
        values['capturePurpose'] = 'active_discovery';
      }
      if (values['pinnedMedia'] case final Map pin) {
        final file =
            await File('${directory.path}/$id.original').writeAsBytes(original);
        values['pinnedMedia'] = {
          ...pin,
          'evidenceFile': file.path,
          'cacheModifiedAtMs': values['capturedAtMs'],
        };
      }
      await manifest.writeAsString(jsonEncode(values));
      names[manifest.path] = name;
      snapshots[id] = values;
      return values;
    }

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
                'customer': _other,
                'identitySource': 'ax',
                'unread': !otherAnswered,
                'redClockPresent': !otherAnswered,
                'evidenceAvailable': true,
                'unreadEvidence': otherAnswered ? 0 : 20
              },
            {
              'customer': _customer,
              'identitySource': 'ax',
              'unread': false,
              'redClockPresent': phase != 'baseline' && !aFormal,
              'evidenceAvailable': true,
              'unreadEvidence': 0
            },
          ];
        case 'openConversation':
          active = args['expectedCustomer'] as String;
          return {'opened': true, 'customer': active};
        case 'scrollConversation':
          return {'scrolled': true};
        case 'captureViewportEvidence':
          final customer = args['expectedCustomer'] as String? ?? active;
          return snapshot(customer == _other ? 'other' : phase);
        case 'inspectViewportEvidence':
          final name = names[args['manifestPath']]!;
          observed.update(name, (n) => n + 1, ifAbsent: () => 1);
          if (name == 'first-late') {
            lateOcrStarted = true;
            await lateOcrGate.future;
            lateOcrCompleted = true;
          }
          final captured = jsonDecode(
              await File(args['manifestPath'] as String).readAsString()) as Map;
          return {
            ...ocr[name]!,
            'capturedAtMs': captured['capturedAtMs'],
            'pngBase64': base64Encode(png[name]!)
          };
        case 'captureRecentCachedMedia':
          if (phase != 'first' || args['expectedCustomer'] != _customer) {
            return {'kind': 'none'};
          }
          return {
            'kind': 'image',
            'cacheKey': 'v45-shared-actual-image-$phase',
            'cacheModifiedAtMs': DateTime.now().millisecondsSinceEpoch,
            'dataBase64': base64Encode(original),
            'mimeType': 'image/jpeg',
            'extension': 'jpeg',
            'captureSource': 'jd-image-cache'
          };
        case 'recentMediaCacheRevision':
          return {'revision': 'v45-$phase'};
        case 'cropViewportEvidence':
          final name = names[args['manifestPath']]!;
          cropped.add(name);
          await cropGate.future;
          if (name == 'second-loading') {
            return {
              'kind': 'unverified',
              'reason': 'insufficient_visual_evidence',
              'captureSource': 'frozen-window-crop',
              'foregroundFraction': 0.0,
            };
          }
          final codec =
              await ui.instantiateImageCodec(Uint8List.fromList(png[name]!));
          final decoded = (await codec.getNextFrame()).image;
          final rect = Rect.fromLTWH(
              (args['x'] as num).toDouble() * decoded.width,
              (args['y'] as num).toDouble() * decoded.height,
              (args['width'] as num).toDouble() * decoded.width,
              (args['height'] as num).toDouble() * decoded.height);
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawImageRect(decoded, rect,
              Rect.fromLTWH(0, 0, rect.width, rect.height), Paint());
          final picture = recorder.endRecording();
          final crop =
              await picture.toImage(rect.width.ceil(), rect.height.ceil());
          final encoded =
              (await crop.toByteData(format: ui.ImageByteFormat.png))!;
          final data = base64Encode(encoded.buffer.asUint8List());
          crop.dispose();
          picture.dispose();
          decoded.dispose();
          codec.dispose();
          return {
            'kind': 'image',
            'reason': 'visible_crop_only',
            'captureSource': 'frozen-window-crop',
            'dataBase64': data,
            'cardPreviewDataBase64': data,
            'mimeType': 'image/png',
            'extension': 'png',
            'foregroundFraction': .15,
            'visualFingerprint': '00ffffffff8080ff'
          };
        case 'checkDeliveryReadiness':
          return {
            'ready': active == args['expectedCustomer'],
            'customer': active
          };
        case 'sendDraftOnce':
          final customer = args['expectedCustomer'] as String;
          expect(active, customer);
          final reply = args['reply'] as String;
          if (!isHoldingReply(reply)) {
            formal.add(customer);
            if (customer == _other) otherAnswered = true;
            if (customer == _customer) aFormal = true;
          }
          final stamp = DateTime.now().millisecondsSinceEpoch;
          await File(args['receiptPath'] as String).writeAsString(jsonEncode({
            'attemptId': args['attemptId'],
            'customer': customer,
            'state': 'submitted',
            'sendClickedAtMs': stamp,
            'timeMs': stamp,
          }));
          return {
            'sent': true,
            'customer': customer,
            'activeCustomerId': customer,
            'sendClickedAtMs': stamp,
            'redClockPresentAfterSend': false,
            'redClockObservedAtMs': stamp
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
          reason:
              'phase=$phase observed=$observed crops=$cropped formal=$formal '
              'generations=${generations.map((x) => x.map((m) => m['id']).toList()).toList()} '
              'calls=${calls.take(55).toList()}');
    }

    Future<T> query<T>(Future<T> Function() read) async {
      T? value;
      Object? failure;
      var done = false;
      await tester.runAsync(() async {
        unawaited(read().then((v) {
          value = v;
          done = true;
        }, onError: (Object e) {
          failure = e;
          done = true;
        }));
      });
      await until(() => done);
      if (failure != null) throw failure!;
      return value as T;
    }

    Future<List<Map<String, Object?>>> mediaWork() => query(() async =>
        (await db.database).query('automation_session_messages',
            where: 'session_id=? AND user_id=? AND input_kind=?',
            whereArgs: [db.currentAutomationSessionId, _customer, 'media']));
    Future<void> waitMedia(int count) async {
      for (var i = 0; i < 500; i++) {
        if ((await mediaWork()).length == count) return;
        await tick();
      }
      expect(await mediaWork(), hasLength(count));
    }

    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
      database: db,
      adapter: MacOSCaptureAdapter(channel: channel),
      redClockTracker: RedClockTracker(monotonicMs: () => monotonic),
      scanIntervalOverride: const Duration(milliseconds: 150),
      generateDraftOverride: (customer, database, end, cancellation) async {
        final input = (await database.generationMessages(customer.userId,
                batchEndMessageId: end))
            .where((m) => m['direction'] == 'incoming')
            .toList();
        generations.add(input);
        if (customer.userId == _other) {
          return AiDraft.fromJson({
            'reply': 'Connect USB directly to the computer.',
            'reply_purpose': 'substantive',
            'decision': 'draft',
            'confidence': 1,
            'risk_level': 'low',
            'model': 'controlled-v45-other',
            'auto_send_allowed': true
          }, mediaBaseUrl: Uri());
        }
        aGenerationStarted = true;
        await analysisGate.future;
        final descriptions = <String, String>{};
        for (final message in input) {
          if (message['media_receipt_id'] == null) continue;
          final assets = (message['media'] as List).whereType<Map>().toList();
          expect(assets, isNotEmpty);
          expect(assets.every((asset) => asset['is_partial'] != true), isTrue);
          for (final asset
              in assets.where((asset) => asset['type'] == 'image')) {
            expect(await File(asset['path'] as String).readAsBytes(), original);
            descriptions[asset['path'] as String] =
                'The screenshot shows the Grozziie app home page with Add Other Device.';
          }
        }
        await (await database.history)
            .updateMediaDescriptions(_customer, descriptions);
        return AiDraft.fromJson({
          'reply': 'Tap Add Other Device in the Grozziie app.',
          'reply_purpose': 'substantive',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-v45-photo-analysis',
          'auto_send_allowed': true,
          'image_descriptions': [
            for (final entry in descriptions.entries)
              {'path': entry.key, 'description': entry.value}
          ]
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
    var baselineCommitted = false;
    for (var i = 0; i < 500 && !baselineCommitted; i++) {
      baselineCommitted = await query(() async => (await (await db.database)
              .query('capture_evidence',
                  where: "id='v45-home-baseline' AND state='processed'"))
          .isNotEmpty);
      if (!baselineCommitted) await tick();
    }
    expect(baselineCommitted, isTrue,
        reason: 'First new image must arrive after the baseline commit.');
    phase = 'first';
    await waitMedia(1);
    await until(() => cropped.isNotEmpty);
    expect(formal.where((c) => c == _customer), isEmpty);
    final white = await query(() => snapshot('second-loading'));
    expect(white['unreadArrivalKey'], isNull);
    await query(() => CaptureEvidenceStore(db).record(ViewportEvidence(white)));
    // The actual main inbox observes the frozen white frame without fabricating
    // its missing AX signal. Its following loaded frame has fresh live proof.
    await until(() => (observed['second-loading'] ?? 0) > 0);
    phase = 'second-loaded';
    active = _customer;
    await waitMedia(2);
    final pending = await mediaWork();
    expect(
        pending.map((row) => row['response_state']), everyElement('pending'));
    expect(pending.map((row) => row['message_id']).toSet(), hasLength(2));
    expect(formal.where((c) => c == _customer), isEmpty);
    cropGate.complete();
    await until(() => aGenerationStarted);
    otherArrived = true;
    await until(() => otherAnswered);
    expect(analysisGate.isCompleted, isFalse,
        reason:
            'Another customer continues while image analysis is in progress.');
    expect(formal.where((c) => c == _customer), isEmpty);
    final late = await query(() => snapshot('first-late'));
    expect(late['unreadArrivalKey'], isNull);
    await query(() => CaptureEvidenceStore(db).record(ViewportEvidence(late)));
    await until(() => lateOcrStarted);
    analysisGate.complete();
    var completed = false;
    for (var i = 0; i < 1200; i++) {
      final rows = await mediaWork();
      completed = rows.length == 2 &&
          rows.every((r) => r['response_state'] == 'answered');
      if (completed) break;
      await tick();
    }
    expect(completed, isTrue,
        reason: 'Both distinct image sends require formal coverage.');
    final covered = await mediaWork();
    expect(covered.every((row) => row['answered_attempt_id'] != null), isTrue);
    final formalBeforeOld = formal.length;
    expect(lateOcrGate.isCompleted, isFalse,
        reason: 'Formal delivery cannot wait for unrelated older OCR.');
    lateOcrGate.complete();
    await until(() => lateOcrCompleted);
    await tick(steps: 60);
    expect(await mediaWork(), hasLength(2));
    expect(formal.length, formalBeforeOld,
        reason: 'Late reads of an answered photo cannot start another reply.');
    expect(await query(() => db.hasPendingUnanswered(_customer)), isFalse);
    expect(await query(() => db.hasPendingUnanswered(_other)), isFalse);
    expect(calls.where((call) => call == 'transcribeAudio'), isEmpty);
    await tester.runAsync(() => tester.tap(find.text('Stop automation')));
    await tick(steps: 15);
  });
}
