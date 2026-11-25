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
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

import 'helpers/run_permissions.dart';

const _customer = 'jd_41aeec7741d05';
const _other = 'jd_v47_parallel_customer';
const _fixtures = 'test/fixtures/v47_video_obligations';

void main() {
  testWidgets(
      'two recorded video sends retain independent duties through A4 generation, moving bubbles and late OCR',
      (tester) async {
    const channel = MethodChannel('v47-recorded-video-flow');
    late Directory root;
    late CaptureDatabase db;
    late CodexReplyService service;
    late File cliRequests;
    late File a4Hold;
    late String originalVideo;
    final png = <String, List<int>>{};
    final ocr = <String, Map<String, Object?>>{};
    final recorded = <String, Map<String, Object?>>{};
    final snapshots = <String, Map<String, Object?>>{};
    final manifestNames = <String, String>{};
    final inspected = <String, int>{};
    final cropped = <String>[];
    final physicalSends = <Map<String, Object?>>[];
    final cropGate = Completer<void>();
    final audioGate = Completer<void>();
    final lateOcrGate = Completer<void>();
    var audioStarted = false;
    var lateOcrStarted = false;
    var lateOcrCompleted = false;
    var phase = 'baseline';
    var active = _customer;
    var otherArrived = false;
    var otherAnswered = false;
    var redPresent = false;
    var monotonic = 0;
    var arrival = 0;
    var completed = false;
    late DateTime firstVideoAt;
    late DateTime secondVideoAt;

    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_v47_recorded_video_');
      db = CaptureDatabase(storageRoot: root);
      final provenance =
          jsonDecode(await File('$_fixtures/provenance.json').readAsString())
              as Map;
      for (final name in [
        'baseline',
        'a4',
        'first-low',
        'first-clear',
        'first-history',
        'second',
        'second-late'
      ]) {
        png[name] = await File('$_fixtures/$name.png').readAsBytes();
        final raw = await File('$_fixtures/$name.ocr.json').readAsBytes();
        final capture =
            await File('$_fixtures/$name.capture.json').readAsBytes();
        expect(sha256.convert(png[name]!).toString(),
            provenance['frames'][name]['pngSHA256']);
        expect(sha256.convert(raw).toString(),
            provenance['frames'][name]['ocr.jsonSHA256']);
        expect(sha256.convert(capture).toString(),
            provenance['frames'][name]['capture.jsonSHA256']);
        ocr[name] =
            Map<String, Object?>.from(jsonDecode(utf8.decode(raw)) as Map);
        recorded[name] =
            Map<String, Object?>.from(jsonDecode(utf8.decode(capture)) as Map);
      }
      final original =
          await File('$_fixtures/resent-original.mp4').readAsBytes();
      expect(original.length, 4795831);
      expect(sha256.convert(original).toString(),
          provenance['original']['sha256']);
      originalVideo = (await File('$_fixtures/resent-original.mp4')
              .copy('${root.path}/same-customer-original.mp4'))
          .path;

      // Map every recorded sender clock to one consistent current-session
      // timeline. Pixels/confidences/regions stay byte-identical; no fixed
      // morning clock may parse as yesterday during an afternoon test run.
      final clock = RegExp(r'(?<!\d)(\d{1,2})[:：](\d{2})[:：](\d{2})(?!\d)');
      DateTime originalAt(Map source, Match match) {
        final captured = DateTime.fromMillisecondsSinceEpoch(
                source['capturedAtMs'] as int,
                isUtc: true)
            .add(const Duration(hours: 8));
        return DateTime.utc(
                captured.year,
                captured.month,
                captured.day,
                int.parse(match[1]!),
                int.parse(match[2]!),
                int.parse(match[3]!))
            .subtract(const Duration(hours: 8));
      }

      final originals = <DateTime>{
        DateTime.utc(2026, 11, 10, 4, 26, 14),
        DateTime.utc(2026, 11, 10, 4, 27, 11),
      };
      for (final source in ocr.values) {
        for (final line in (source['observations'] as List).cast<Map>()) {
          for (final match in clock.allMatches(line['text'] as String)) {
            originals.add(originalAt(source, match));
          }
        }
      }
      final times = originals.toList()..sort();
      final a4Index = times.indexOf(DateTime.utc(2026, 11, 10, 4, 25, 52));
      expect(a4Index, isNonNegative);
      final now = DateTime.now().toUtc();
      final base = DateTime.utc(
              now.year, now.month, now.day, now.hour, now.minute, now.second)
          .subtract(Duration(seconds: a4Index));
      DateTime mapped(DateTime at) =>
          base.add(Duration(seconds: times.indexOf(at)));
      firstVideoAt = mapped(DateTime.utc(2026, 11, 10, 4, 26, 14));
      secondVideoAt = mapped(DateTime.utc(2026, 11, 10, 4, 27, 11));
      expect(secondVideoAt.isAfter(firstVideoAt), isTrue);
      for (final source in ocr.values) {
        source['observations'] = [
          for (final line in (source['observations'] as List).cast<Map>())
            {
              ...line,
              'text': (line['text'] as String).replaceAllMapped(clock, (match) {
                final at = mapped(originalAt(source, match))
                    .add(const Duration(hours: 8));
                return '${at.hour.toString().padLeft(2, '0')}:'
                    '${at.minute.toString().padLeft(2, '0')}:'
                    '${at.second.toString().padLeft(2, '0')}';
              })
            }
        ];
      }
      final knowledge = await Directory('${root.path}/knowledge').create();
      final workspace = await Directory('${root.path}/workspace').create();
      await File('${knowledge.path}/printer_kb.md').writeAsString(
          'TD630 accepts A4 paper. Check the paper feed and use the supplied USB cable.');
      cliRequests = File('${root.path}/cli-requests.jsonl');
      a4Hold = await File('${root.path}/a4-hold')
          .writeAsString('hold submitted A4 turn');
      final cli =
          await File('${root.path}/cli.py').writeAsString('''#!/usr/bin/python3
import sys,re,json,pathlib,time
args=sys.argv[1:]
text=sys.stdin.read()
request=json.loads(re.search(r'<request_json>\\s*([\\s\\S]*?)\\s*</request_json>',text).group(1))
batch=request['target_customer_batch']
with pathlib.Path(${jsonEncode(cliRequests.path)}).open('a') as f: f.write(json.dumps(request)+'\\n')
if any('support a4 size paper' in m.get('body','').lower() for m in batch):
    while pathlib.Path(${jsonEncode(a4Hold.path)}).exists(): time.sleep(.005)
media=bool(request['attached_video_frame_paths']) or any(m.get('media') for m in batch)
reply='The video shows the paper feed. Switch off the printer and reload the paper correctly.' if media else ('Connect the supplied USB cable directly to the computer.' if request['user_id']==${jsonEncode(_other)} else 'Yes, the TD630 supports plain A4 paper. It accepts paper widths of 100–241 mm, with a maximum printable width of about 203 mm, so leave side margins in your document.')
result={'reply':reply,'reply_purpose':'substantive','decision':'draft','confidence':.99,'risk_level':'low','auto_send_allowed':False,'human_review_required':False,'risk_triggers':[],'used_record_ids':[],'required_slots':[],'actions':[],'attachments':[],'image_descriptions':[{'path':p,'description':'The complete supplied video frame shows the printer paper feed and the customer handling the printer.'} for p in request['attached_image_paths']]}
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(json.dumps(result))
''');
      expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
      service = CodexReplyService(
          executable: cli.path,
          workspace: workspace,
          knowledgeDirectory: knowledge,
          outputSchema: File('${root.path}/reply.schema.json'),
          timeout: const Duration(seconds: 60),
          capacityRetryDelays: const []);
    });
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      for (final gate in [cropGate, audioGate, lateOcrGate]) {
        if (!gate.isCompleted) gate.complete();
      }
      await tester.runAsync(() async {
        if (await a4Hold.exists()) await a4Hold.delete();
      });
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        Object? closeError;
        try {
          await db.close().timeout(const Duration(seconds: 5));
        } catch (error) {
          closeError = error;
        }
        final artifactRoot = Platform.environment['JD_TEST_ARTIFACT_ROOT'];
        if (!completed && artifactRoot != null && artifactRoot.isNotEmpty) {
          final target = await Directory(
                  '$artifactRoot/v47-recorded-video-${DateTime.now().microsecondsSinceEpoch}')
              .create(recursive: true);
          await File('${target.path}/test-state.json')
              .writeAsString(jsonEncode({
            'temporaryRoot': root.path,
            'phase': phase,
            'inspected': inspected,
            'cropped': cropped,
            'audioStarted': audioStarted,
            'lateOcrStarted': lateOcrStarted,
            'lateOcrCompleted': lateOcrCompleted,
            'physicalSends': physicalSends,
            'closeError': closeError?.toString(),
          }));
          await for (final entity
              in root.list(recursive: true, followLinks: false)) {
            final path =
                '${target.path}/${entity.path.substring(root.path.length + 1)}';
            if (entity is Directory) {
              await Directory(path).create(recursive: true);
            } else if (entity is File) {
              await File(path).parent.create(recursive: true);
              try {
                await entity.copy(path);
              } on FileSystemException {
                // An already cancelled writer may finish/remove its private
                // temp file. Durable source files and the DB remain available.
              }
            }
          }
          // ignore: avoid_print
          print('v47 failure artifacts: ${target.path}');
        }
        // Preserve a failed fixture when no artifact root was supplied, too.
        if (completed && closeError == null && await root.exists()) {
          await root.delete(recursive: true);
        }
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<Map<String, Object?>> snapshot(String name,
        {bool history = false}) async {
      final key = history ? 'history-$name' : name;
      if (snapshots[key] case final previous?) return previous;
      final source = recorded[name] ?? recorded['a4']!;
      final directory = await Directory('${root.path}/capture_evidence')
          .create(recursive: true);
      final image = await File('${directory.path}/$key.png')
          .writeAsBytes(png[name] ?? png['a4']!);
      final manifest = File('${directory.path}/$key.json');
      final metadata = <String, Object?>{
        for (final field in [
          'windowBounds',
          'windowTitle',
          'windowId',
          'imageWidth',
          'imageHeight',
          'chatRegion'
        ])
          if (source[field] != null) field: source[field],
        'evidenceId': 'v47-home-$key',
        'customer': name == 'other' ? _other : _customer,
        'automationSessionId': db.currentAutomationSessionId,
        'capturedAtMs': DateTime.now().millisecondsSinceEpoch,
        'imagePath': image.path,
        'manifestPath': manifest.path,
        'pngSHA256': sha256.convert(png[name] ?? png['a4']!).toString(),
        'chatContentSHA256': 'recorded-v47-$key',
        'recordedEvidenceId': source['evidenceId'],
        if (history) ...{
          'capturePurpose': 'history_backfill',
          'historyCutoffMs': DateTime.now().millisecondsSinceEpoch,
          'replyActivationAllowed': false,
        },
      };
      await manifest.writeAsString(jsonEncode(metadata));
      manifestNames[manifest.path] = name;
      snapshots[key] = metadata;
      return metadata;
    }

    Future<String> cropPng(String name, Map args) async {
      final codec =
          await ui.instantiateImageCodec(Uint8List.fromList(png[name]!));
      final decoded = (await codec.getNextFrame()).image;
      final box = Rect.fromLTWH(
          (args['x'] as num).toDouble() * decoded.width,
          (args['y'] as num).toDouble() * decoded.height,
          (args['width'] as num).toDouble() * decoded.width,
          (args['height'] as num).toDouble() * decoded.height);
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
          decoded, box, Rect.fromLTWH(0, 0, box.width, box.height), Paint());
      final picture = recorder.endRecording();
      final image = await picture.toImage(box.width.ceil(), box.height.ceil());
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final result = base64Encode(bytes.buffer.asUint8List());
      image.dispose();
      picture.dispose();
      decoded.dispose();
      codec.dispose();
      return result;
    }

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
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
                'unreadEvidence': otherAnswered ? 0 : 101
              },
            {
              'customer': _customer,
              'identitySource': 'ax',
              'unread': redPresent,
              'redClockPresent': redPresent,
              'evidenceAvailable': true,
              'unreadEvidence': redPresent ? arrival : 0
            }
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
          final name = manifestNames[args['manifestPath']]!;
          inspected.update(name, (n) => n + 1, ifAbsent: () => 1);
          if (name == 'first-history') {
            lateOcrStarted = true;
            await lateOcrGate.future;
            lateOcrCompleted = true;
          }
          final metadata = jsonDecode(
              await File(args['manifestPath'] as String).readAsString()) as Map;
          if (name == 'other') {
            final jd = DateTime.fromMillisecondsSinceEpoch(
                    metadata['capturedAtMs'] as int,
                    isUtc: true)
                .add(const Duration(hours: 8));
            return {
              'windowId': 1,
              'activeCustomerId': _other,
              'imageWidth': 2880,
              'imageHeight': 1626,
              'capturedAtMs': metadata['capturedAtMs'],
              'chatRegion': metadata['chatRegion'],
              'visualRegions': <Object>[],
              'observations': [
                {
                  'text':
                      '$_other ${jd.hour.toString().padLeft(2, '0')}:${jd.minute.toString().padLeft(2, '0')}:${jd.second.toString().padLeft(2, '0')}',
                  'confidence': 1.0,
                  'x': .27,
                  'y': .30,
                  'width': .3,
                  'height': .02
                },
                {
                  'text': 'How do I connect the USB cable?',
                  'confidence': 1.0,
                  'x': .28,
                  'y': .35,
                  'width': .3,
                  'height': .02
                }
              ]
            };
          }
          return {
            ...ocr[name]!,
            'capturedAtMs': metadata['capturedAtMs'],
            'pngBase64': base64Encode(png[name]!)
          };
        case 'recentMediaCacheRevision':
          return {'revision': 'v47-$phase'};
        case 'captureRecentCachedMedia':
          if (phase == 'baseline' ||
              phase == 'a4' ||
              args['expectedCustomer'] != _customer) {
            return {'kind': 'none'};
          }
          return {
            'kind': 'video',
            'cacheKey': 'actual-resent-video',
            'cacheModifiedAtMs': DateTime.now().millisecondsSinceEpoch,
            'path': originalVideo,
            'originalName': 'resent-original.mp4',
            'mimeType': 'video/mp4'
          };
        case 'cropViewportEvidence':
          final name = manifestNames[args['manifestPath']]!;
          expect(name, isNot(anyOf('baseline', 'a4', 'other')));
          cropped.add(name);
          await cropGate.future;
          final preview = await cropPng(name, args);
          return {
            'kind': 'video',
            'reason': 'pixel_matched_same_chat_video_companion',
            'captureSource': 'frozen-frame-video-cache',
            'playbackOverlayDetected': true,
            'visualFingerprint': '1234567890abcdef',
            'dataBase64': preview,
            'cardPreviewDataBase64': preview,
            'video': {
              'path': originalVideo,
              'originalName': 'resent-original.mp4',
              'mimeType': 'video/mp4'
            }
          };
        case 'transcribeAudio':
          audioStarted = true;
          await audioGate.future;
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
          expect(active, args['expectedCustomer']);
          final reply = args['reply'] as String;
          final customer = args['expectedCustomer'] as String;
          physicalSends.add({
            'customer': customer,
            'reply': reply,
            'holding': isHoldingReply(reply)
          });
          if (customer == _other && !isHoldingReply(reply)) {
            otherAnswered = true;
          }
          if (customer == _customer) redPresent = false;
          final stamp = DateTime.now().millisecondsSinceEpoch;
          await File(args['receiptPath'] as String).writeAsString(jsonEncode({
            'attemptId': args['attemptId'],
            'customer': customer,
            'state': 'submitted',
            'timeMs': stamp,
            'sendClickedAtMs': stamp
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

    Future<void> tick() async {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }

    Future<T> query<T>(Future<T> Function() read) async {
      T? result;
      Object? failure;
      var done = false;
      await tester.runAsync(() async {
        unawaited(read().then((value) {
          result = value;
          done = true;
        }, onError: (Object error) {
          failure = error;
          done = true;
        }));
      });
      for (var i = 0; i < 3000 && !done; i++) {
        await tick();
      }
      if (failure != null) throw failure!;
      expect(done, isTrue, reason: 'Database/file read did not complete');
      return result as T;
    }

    Future<List<Map<String, Object?>>> mediaWork() => query(() async =>
        (await db.database).query('automation_session_messages',
            where: 'session_id=? AND user_id=? AND input_kind=?',
            whereArgs: [db.currentAutomationSessionId, _customer, 'media'],
            orderBy: 'rowid'));
    Future<List<Map>> requests() => query(() async => await cliRequests.exists()
        ? (await cliRequests.readAsLines())
            .map((line) => jsonDecode(line) as Map)
            .toList()
        : []);
    Future<void> until(Future<bool> Function() ready, String stage) async {
      for (var i = 0; i < 3000; i++) {
        if (await ready()) return;
        await tick();
      }
      final work = await mediaWork();
      final evidence = await query(() async => (await db.database).query(
          'capture_evidence',
          columns: ['id', 'state', 'attempts', 'last_error']));
      fail('$stage temp=${root.path} phase=$phase inspected=$inspected '
          'crops=$cropped audio=$audioStarted late=$lateOcrStarted '
          'media=$work evidence=$evidence sends=$physicalSends');
    }

    Future<bool> processed(String name) =>
        query(() async => (await (await db.database).query('capture_evidence',
                where: 'id=? AND state=?',
                whereArgs: ['v47-home-$name', 'processed']))
            .isNotEmpty);
    List<Map<String, Object?>> formalSends(String customer) => physicalSends
        .where((s) => s['customer'] == customer && s['holding'] == false)
        .toList();

    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
            database: db,
            adapter: MacOSCaptureAdapter(channel: channel),
            replyServiceOverride: service,
            redClockTracker: RedClockTracker(monotonicMs: () => monotonic),
            scanIntervalOverride: const Duration(milliseconds: 100))));
    await grantRunPermissions(tester);
    await tester.runAsync(() => tester.tap(find.text('Start automation')));
    await until(() => processed('baseline'), 'fully committed Start baseline');
    expect(await mediaWork(), isEmpty);
    phase = 'a4';
    redPresent = true;
    arrival++;
    await until(
        () async => (await requests()).any((r) =>
            (r['target_customer_batch'] as List).any((m) =>
                (m['body'] as String).contains('support a4 size paper'))),
        'submitted A4 CLI');
    expect(formalSends(_customer), isEmpty);
    phase = 'first-low';
    await until(() async => (await mediaWork()).length == 1,
        'first low-confidence-header video duty');
    await until(() async => cropped.isNotEmpty,
        'first video original acquisition started');
    final firstOwner = (await mediaWork()).single['message_id'];
    monotonic += 21000;
    await until(
        () async => physicalSends
            .any((s) => s['customer'] == _customer && s['holding'] == true),
        'one red-cycle holding');
    expect((await mediaWork()).single['response_state'], 'pending',
        reason: 'A holding receipt never formally answers the video');
    expect(formalSends(_customer), isEmpty);
    await query(() => a4Hold.delete());
    await until(() async => formalSends(_customer).length == 1,
        'A4 native formal reply');
    phase = 'first-clear';
    await until(() async => (inspected['first-clear'] ?? 0) > 0,
        'same first video moves above A4 reply');
    expect(await mediaWork(), hasLength(1));

    // Retain an actual earlier frozen page, not a fabricated message owner.
    // Its OCR stays held while new live arrivals use the independent lane.
    final late = await query(() => snapshot('first-history', history: true));
    await query(() => CaptureEvidenceStore(db).record(ViewportEvidence(late)));
    await until(() async => lateOcrStarted, 'late immutable historical OCR');
    phase = 'second';
    redPresent = true;
    arrival++;
    await until(() async => (await mediaWork()).length == 2,
        'second same-file send is an independent duty');
    final owners =
        (await mediaWork()).map((w) => w['message_id'] as String).toSet();
    expect(owners, contains(firstOwner));
    expect(owners, hasLength(2));
    phase = 'second-late';
    await until(() async => (inspected['second-late'] ?? 0) > 0,
        'overlap header clears on moving video');
    expect((await mediaWork()).map((w) => w['message_id']).toSet(), owners);
    otherArrived = true;
    await until(() async => otherAnswered,
        'different customer replies while video/OCR are held');
    expect(cropGate.isCompleted, isFalse);
    expect(lateOcrGate.isCompleted, isFalse);
    expect(await query(() => db.hasPendingUnanswered(_other)), isFalse);
    cropGate.complete();
    await until(() async => audioStarted, 'unchanged real MP4 audio pipeline');
    await until(() async {
      final document =
          await query(() async => (await db.history).read(_customer));
      final messages = (document?['messages'] as List? ?? []).whereType<Map>();
      return owners.every((id) => messages.any((m) =>
          m['id'] == id &&
          (m['media'] as List? ?? [])
              .whereType<Map>()
              .any((a) => a['type'] == 'video')));
    }, 'both exact owners receive the original video and full decoded frames');
    expect((await mediaWork()).every((w) => w['response_state'] == 'pending'),
        isTrue);
    expect(formalSends(_customer), hasLength(1),
        reason: 'No media formal answer before the speech terminal result');
    expect(
        (await requests()).where((r) =>
            r['user_id'] == _customer &&
            (r['target_customer_batch'] as List)
                .any((m) => (m['media'] as List? ?? []).isNotEmpty)),
        isEmpty,
        reason:
            'Media may not enter the actual CLI before all parsing finishes');
    audioGate.complete();
    await until(
        () async =>
            (await mediaWork()).every((w) => w['response_state'] == 'answered'),
        'every independently received video formally answered');
    final beforeLate = formalSends(_customer).length;
    final beforeRequests = (await requests()).length;
    lateOcrGate.complete();
    await until(() async => lateOcrCompleted, 'late OCR released');
    await until(() async => await processed('history-first-history'),
        'late historical page settled');
    expect((await mediaWork()).map((w) => w['message_id']).toSet(), owners);
    expect(formalSends(_customer), hasLength(beforeLate));
    expect(await requests(), hasLength(beforeRequests));
    final attempts = await query(() async => (await db.database).query(
        'delivery_attempts',
        where: 'user_id=? AND kind=?',
        whereArgs: [_customer, 'reply']));
    final mediaRequests = (await requests())
        .where((r) =>
            r['user_id'] == _customer &&
            (r['target_customer_batch'] as List)
                .any((m) => (m['media'] as List? ?? []).isNotEmpty))
        .toList();
    expect(mediaRequests, isNotEmpty);
    expect(
        mediaRequests
            .expand(
                (r) => (r['target_customer_batch'] as List).map((m) => m['id']))
            .toSet(),
        owners);
    expect(
        mediaRequests
            .every((r) => (r['attached_video_frame_paths'] as List).length > 1),
        isTrue);
    for (final owner in owners) {
      final covering = attempts
          .where((a) => (jsonDecode(a['raw_json'] as String)[
                      'formal_response_message_ids'] as List? ??
                  [])
              .contains(owner))
          .toList();
      expect(covering, hasLength(1),
          reason: 'One formal coverage for physical video duty $owner');
      final receipt = await query(() async => jsonDecode(await File(
              '${root.path}/delivery_receipts/${covering.single['attempt_id']}.json')
          .readAsString()) as Map);
      expect(receipt['customer'], _customer);
      expect(receipt['state'], 'submitted');
    }
    final document =
        await query(() async => (await db.history).read(_customer));
    final messages = (document!['messages'] as List).whereType<Map>();
    for (final owner in owners) {
      final message = messages.singleWhere((m) => m['id'] == owner);
      final assets = (message['media'] as List).whereType<Map>().toList();
      final video = assets.singleWhere((a) => a['type'] == 'video');
      expect(
          await query(() async => sha256
              .convert(await File(video['path'] as String).readAsBytes())
              .toString()),
          'cf7fb5a192295028719ff17495f19f6d849152463fe1f6ac081a98c34e7667e8');
      final frames = assets
          .where((a) => a['capture_source'] == 'jd_video_frame_1fps')
          .toList();
      expect(frames.length, greaterThan(1));
      final sampling = await query(() async => jsonDecode(await File(
              '${File(frames.first['path'] as String).parent.path}/sampling.json')
          .readAsString()) as Map);
      expect(sampling['contract'], 'first-and-last-full-span-v3');
      expect(sampling['fullRange'], isTrue);
      expect(frames, hasLength((sampling['frames'] as List).length),
          reason:
              'The existing video pipeline must retain every declared sample');
      expect(
          frames.every((f) =>
              (f['description']?.toString().trim() ?? '').isNotEmpty &&
              !f['description'].toString().contains('pending Codex') &&
              !f['description'].toString().contains('Pending Codex')),
          isTrue);
      expect(
          assets.every((a) =>
              a['is_partial'] != true ||
              a['capture_source'] == 'jd_video_cover'),
          isTrue);
      expect(
          message['sent_at'],
          (owner == firstOwner ? firstVideoAt : secondVideoAt)
              .toIso8601String(),
          reason: 'The two physical sends retain their own sender clocks');
    }
    expect(await query(() => db.unansweredWorkCounts()), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => tester.tap(find.text('Stop automation')));
    await tick();
    completed = true;
  }, skip: !Platform.isMacOS);
}
