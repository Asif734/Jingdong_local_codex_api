import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/red_clock_tracker.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/codex/holding_replies.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

import 'helpers/run_permissions.dart';

const _customer = 'jd_5f2331ef08167';
const _fixtures = 'test/fixtures/v46_unknown_incoming';
const _reply = '请问现在电脑上显示什么提示？我继续帮您排查 USB 连接。';

void main() {
  testWidgets(
      'CaptureHome registers actual unread question beside an unfinished photo then refines the same owner and sends once',
      (tester) async {
    const channel = MethodChannel('v46-home-actual-unknown-body');
    late Directory root;
    late CaptureDatabase db;
    late Map<String, Object?> raw;
    late Map<String, Object?> sourceMetadata;
    late Map<String, Object?> provenance;
    late List<int> png;
    late List<Map<String, Object?>> nativeRepeat;
    final snapshots = <String, Map<String, Object?>>{};
    final names = <String, String>{};
    final calls = <String>[];
    final nativeArguments = <Map<String, Object?>>[];
    var failureSaved = false;
    final inspected = <String, int>{};
    final formal = <String>[];
    final generated = <List<Map<String, dynamic>>>[];
    final refineGate = Completer<void>();
    final lateOcrGate = Completer<void>();
    var phase = 'baseline';
    var active = _customer;
    var nativeCalls = 0;
    var stopping = false;
    var closed = false;
    var running = false;
    var refineEntered = false;
    var busyReturned = false;
    var refinementRequests = 0;
    var refined = false;
    var lateEntered = false;
    var lateCompleted = false;
    late Duration clockShift;
    late DateTime questionAt;
    String? oldPhotoId;
    String? questionId;

    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('jd_v46_home_unknown_');
      db = CaptureDatabase(storageRoot: root);
      await db.database;
      await db.history;
      provenance = Map<String, Object?>.from(
          jsonDecode(await File('$_fixtures/provenance.json').readAsString())
              as Map);
      final info = (provenance['frames'] as Map)['0e40'] as Map;
      png = await File('$_fixtures/0e40.png').readAsBytes();
      final bytes = await File('$_fixtures/0e40.ocr.json').readAsBytes();
      final capture = await File('$_fixtures/0e40.capture.json').readAsBytes();
      expect(sha256.convert(png).toString(), info['pngSHA256']);
      expect(sha256.convert(bytes).toString(), info['ocr.jsonSHA256']);
      expect(sha256.convert(capture).toString(), info['capture.jsonSHA256']);
      raw = Map<String, Object?>.from(jsonDecode(utf8.decode(bytes)) as Map);
      sourceMetadata =
          Map<String, Object?>.from(jsonDecode(utf8.decode(capture)) as Map);
      final native =
          await File('$_fixtures/0e40.native-repeat.json').readAsBytes();
      expect(sha256.convert(native).toString(),
          (provenance['nativeRepeat'] as Map)['sha256']);
      final repeats = jsonDecode(utf8.decode(native)) as List;
      expect(repeats, hasLength(3));
      for (final repeat in repeats.cast<List>()) {
        expect((repeat.single as Map)['text'], '？');
        expect((repeat.single as Map)['confidence'], .5);
      }
      nativeRepeat = (repeats.first as List)
          .cast<Map>()
          .map((line) => Map<String, Object?>.from(line))
          .toList();
    });
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> tick({int count = 1}) async {
      for (var i = 0; i < count; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<T> query<T>(Future<T> Function() work) async {
      T? value;
      Object? error;
      var complete = false;
      await tester.runAsync(() async {
        unawaited(work().then((result) {
          value = result;
          complete = true;
        }, onError: (Object failure) {
          error = failure;
          complete = true;
        }));
      });
      for (var i = 0; i < 500 && !complete; i++) {
        await tick();
      }
      expect(complete, isTrue, reason: 'File/SQL work must finish with pumps.');
      if (error != null) throw error!;
      return value as T;
    }

    Future<void> saveFailure(String stage) async {
      if (failureSaved) return;
      failureSaved = true;
      final artifactRoot = Platform.environment['JD_TEST_ARTIFACT_ROOT'] ??
          '${Directory.current.path}/work/jd-v46-fixes';
      final destination = Directory('$artifactRoot/failed-home-unknown-'
          '${DateTime.now().microsecondsSinceEpoch}');
      await query(() async {
        await destination.create(recursive: true);
        final sql = await db.database;
        final tables = <String, Object?>{};
        for (final table in [
          'automation_session_messages',
          'customer_media_items',
          'media_card_observations',
          'media_capture_audit',
          'capture_evidence',
          'automation_sessions',
          'drafts',
          'pending_customers'
        ]) {
          final present = await sql.rawQuery(
              "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
              [table]);
          if (present.isNotEmpty) tables[table] = await sql.query(table);
        }
        await sql
            .execute('VACUUM INTO ?', ['${destination.path}/snapshot.sqlite3']);
        await File('${destination.path}/failure.json')
            .writeAsString(jsonEncode({
          'stage': stage,
          'phase': phase,
          'sessionId': db.currentAutomationSessionId,
          'sessionStartedAt':
              db.automationSessionStartedAt?.toUtc().toIso8601String(),
          'questionAt': snapshots.containsKey('question')
              ? questionAt.toIso8601String()
              : null,
          'oldPhotoId': oldPhotoId,
          'questionId': questionId,
          'refineEntered': refineEntered,
          'busyReturned': busyReturned,
          'refinementRequests': refinementRequests,
          'generated': generated,
          'formal': formal,
          'native': nativeArguments,
          'snapshots': snapshots,
          'tables': tables,
        }));
      });
      // A failed temporary fixture is retained independently of normal cleanup.
      // No production log/data path is read or written by this diagnostic.
      // ignore: avoid_print
      print('V46_UNKNOWN_FAILURE_ARTIFACT=${destination.path}');
    }

    Future<void> until(Future<bool> Function() ready,
        {String stage = '', int limit = 500}) async {
      for (var i = 0; i < limit; i++) {
        if (await ready()) return;
        await tick();
      }
      await saveFailure(stage);
      expect(await ready(), isTrue,
          reason: '$stage phase=$phase refine=$refineEntered/$refined '
              'generated=$generated formal=$formal native=$calls');
    }

    Future<List<Map<String, Object?>>> work() => query(() async =>
        (await db.database).query('automation_session_messages',
            where: 'session_id=? AND user_id=?',
            whereArgs: [db.currentAutomationSessionId, _customer],
            orderBy: 'activated_at_ms,rowid'));

    Map<String, Object?> shiftedOcr(String name, Map values) {
      final baseline = name == 'baseline';
      String shiftClock(String text) => text.replaceAllMapped(
              RegExp(r'(?<!\d)(\d{1,2})[:：](\d{2})[:：](\d{2})(?!\d)'), (m) {
            final at = DateTime.utc(2026, 11, 10, int.parse(m[1]!),
                    int.parse(m[2]!), int.parse(m[3]!))
                .add(clockShift);
            return '${at.hour.toString().padLeft(2, '0')}:'
                '${at.minute.toString().padLeft(2, '0')}:'
                '${at.second.toString().padLeft(2, '0')}';
          });
      return {
        ...raw,
        'activeCustomerId': _customer,
        'evidenceId': values['evidenceId'],
        'capturedAtMs': values['capturedAtMs'],
        'pngBase64': base64Encode(png),
        'observations': baseline
            ? <Object>[]
            : [
                for (final line in (raw['observations'] as List).cast<Map>())
                  {...line, 'text': shiftClock(line['text'] as String)}
              ],
        'visualRegions': baseline ? <Object>[] : raw['visualRegions'],
        'unboundMediaRegions': <Object>[],
      };
    }

    Future<Map<String, Object?>> snapshot(String name) async {
      if (snapshots[name] case final previous?) return previous;
      if (stopping) throw PlatformException(code: 'automation_stopped');
      final directory =
          await Directory('${root.path}/capture_evidence').create();
      final id = 'v46-home-unknown-$name';
      final image = await File('${directory.path}/$id.png').writeAsBytes(png);
      final manifest = File('${directory.path}/$id.json');
      final at = name == 'late-old'
          ? (snapshots['question']!['capturedAtMs']! as int) + 1
          : DateTime.now().millisecondsSinceEpoch;
      final values = <String, Object?>{
        'evidenceId': id,
        'customer': _customer,
        'automationSessionId': db.currentAutomationSessionId,
        'capturedAtMs': at,
        'windowId': sourceMetadata['windowId'],
        'windowTitle': sourceMetadata['windowTitle'],
        'windowBounds': sourceMetadata['windowBounds'],
        'imageWidth': sourceMetadata['imageWidth'],
        'imageHeight': sourceMetadata['imageHeight'],
        'chatRegion': sourceMetadata['chatRegion'],
        'imagePath': image.path,
        'manifestPath': manifest.path,
        'pngSHA256': sha256.convert(png).toString(),
        'chatContentSHA256': 'actual-0e40-$name',
        'recordedEvidenceId': sourceMetadata['evidenceId'],
        if (name != 'baseline') ...{
          'replyActivationAllowed': true,
          'capturePurpose': 'active_discovery',
          if (oldPhotoId != null)
            'admissionFrontier': {
              'id': oldPhotoId,
              'direction': 'incoming',
              'sent_at': questionAt
                  .subtract(const Duration(seconds: 97))
                  .toIso8601String(),
              'body': '[Customer sent an image; original still loading]',
            },
        },
      };
      // No original is invented for the old photo: this test deliberately
      // keeps its original/analysis unfinished while the independent ? replies.
      await manifest.writeAsString(jsonEncode(values));
      snapshots[name] = values;
      names[manifest.path] = name;
      return values;
    }

    Future<Object?> native(MethodCall call) async {
      calls.add(call.method);
      final args = Map<String, Object?>.from(call.arguments as Map? ?? {});
      nativeArguments.add({
        'method': call.method,
        'args': args,
        'phase': phase,
        'at': DateTime.now().toUtc().toIso8601String()
      });
      switch (call.method) {
        case 'prepareRunPermissions':
        case 'runPermissionsStatus':
          return {'ready': true};
        case 'status':
          return {'trusted': true};
        case 'setAutomationEpoch':
          return <String, Object?>{};
        case 'ensureReceptionWindow':
          return {'opened': true};
        case 'listConversationRows':
          return [
            {
              'customer': _customer,
              'identitySource': 'ax',
              'unread': phase != 'baseline' && formal.isEmpty,
              'redClockPresent': phase != 'baseline' && formal.isEmpty,
              'evidenceAvailable': true,
              'unreadEvidence': phase == 'baseline' ? 0 : 1,
            }
          ];
        case 'openConversation':
          active = args['expectedCustomer']! as String;
          return {'opened': true, 'customer': active};
        case 'scrollConversation':
          return {'scrolled': true};
        case 'recentMediaCacheRevision':
          return {'revision': 'old-photo-original-unavailable'};
        case 'captureRecentCachedMedia':
          return {'kind': 'none'};
        case 'captureViewportEvidence':
          if (stopping) throw PlatformException(code: 'automation_stopped');
          return snapshot(phase);
        case 'inspectViewportEvidence':
          final name = names[args['manifestPath']]!;
          inspected.update(name, (count) => count + 1, ifAbsent: () => 1);
          if (name == 'late-old') {
            lateEntered = true;
            await lateOcrGate.future;
            lateCompleted = true;
          }
          final values = jsonDecode(
                  await File(args['manifestPath']! as String).readAsString())
              as Map;
          return shiftedOcr(name, values);
        case 'refineEvidenceText':
          final crop = (provenance['nativeRepeat'] as Map)['crop'] as Map;
          final exact = ['x', 'y', 'width', 'height'].every((key) =>
              ((args[key]! as num).toDouble() - (crop[key]! as num).toDouble())
                  .abs() <
              .0000001);
          if (!exact) return {'observations': <Object>[]};
          expect(args['expectedCustomer'], _customer);
          final metadata = jsonDecode(
                  await File(args['manifestPath']! as String).readAsString())
              as Map;
          expect(metadata['recordedEvidenceId'], sourceMetadata['evidenceId']);
          refinementRequests++;
          if (!busyReturned) {
            busyReturned = true;
            return {'busy': true, 'observations': <Object>[]};
          }
          refineEntered = true;
          await refineGate.future;
          refined = true;
          return {'observations': nativeRepeat};
        case 'cropViewportEvidence':
          return {
            'kind': 'unverified',
            'reason': 'old_image_original_not_loaded',
            'captureSource': 'frozen-window-crop',
          };
        case 'checkDeliveryReadiness':
          return {
            'ready': active == args['expectedCustomer'],
            'customer': active
          };
        case 'sendDraftOnce':
          expect(active, _customer);
          expect(args['expectedCustomer'], _customer);
          final reply = args['reply']! as String;
          expect(isHoldingReply(reply), isFalse,
              reason: 'The fake monotonic clock has not reached holding.');
          formal.add(reply);
          final at = DateTime.now().millisecondsSinceEpoch;
          await File(args['receiptPath']! as String).writeAsString(jsonEncode({
            'attemptId': args['attemptId'],
            'customer': _customer,
            'state': 'submitted',
            'sendClickedAtMs': at,
            'timeMs': at
          }));
          return {
            'sent': true,
            'customer': _customer,
            'activeCustomerId': _customer,
            'sendClickedAtMs': at,
            'redClockPresentAfterSend': false,
            'redClockObservedAtMs': at,
          };
      }
      return <String, Object?>{};
    }

    Future<void> shutdown() async {
      if (closed) return;
      stopping = true;
      if (!refineGate.isCompleted) refineGate.complete();
      if (!lateOcrGate.isCompleted) lateOcrGate.complete();
      if (running && find.text('Stop automation').evaluate().isNotEmpty) {
        final dynamic stop = tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Stop automation'))
            .onPressed;
        await query(() async {
          await stop();
          return true;
        });
        running = false;
      }
      await until(() async => nativeCalls == 0, stage: 'native shutdown');
      final history = await query(() => db.history);
      await query(() => history.withCustomerSnapshot(_customer, (_) async {}));
      await query(() async =>
          (await db.database).transaction((txn) => txn.rawQuery('SELECT 1')));
      await tester.pumpWidget(const SizedBox());
      await until(() async => nativeCalls == 0,
          stage: 'disposed native shutdown');
      await query(() => history.withCustomerSnapshot(_customer, (_) async {}));
      await query(() => db.close());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await tester.runAsync(() => root.delete(recursive: true));
      closed = true;
    }

    addTearDown(shutdown);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls++;
      try {
        return await native(call);
      } finally {
        nativeCalls--;
      }
    });
    await tester.pumpWidget(MaterialApp(
        home: CaptureHome(
      database: db,
      adapter: MacOSCaptureAdapter(channel: channel),
      redClockTracker: RedClockTracker(monotonicMs: () => 0),
      scanIntervalOverride: const Duration(milliseconds: 150),
      batchCollectionWindowOverride: Duration.zero,
      generateDraftOverride: (customer, database, end, cancellation) async {
        final inputs = (await database.generationMessages(customer.userId,
                batchEndMessageId: end))
            .where((m) => m['direction'] == 'incoming')
            .toList();
        generated.add(inputs);
        expect(inputs, hasLength(1));
        expect(inputs.single['id'], questionId);
        expect(inputs.single['body'], '？');
        expect(inputs.single['id'], isNot(oldPhotoId));
        return AiDraft.fromJson({
          'reply': _reply,
          'reply_purpose': 'substantive',
          'decision': 'draft',
          'confidence': 1,
          'risk_level': 'low',
          'model': 'controlled-actual-unknown-body',
          'auto_send_allowed': true,
          'actions': [],
          'attachments': []
        }, mediaBaseUrl: Uri());
      },
    )));
    await grantRunPermissions(tester);
    await until(
        () async =>
            tester
                .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Start automation'))
                .onPressed !=
            null,
        stage: 'permissions');
    await tester.runAsync(() => tester.tap(find.text('Start automation')));
    running = true;
    await until(
        () => query(() async => (await (await db.database).query(
                'capture_evidence',
                where: "id='v46-home-unknown-baseline' AND state='processed'"))
            .isNotEmpty),
        stage: 'baseline');
    expect(await work(), isEmpty);
    // Wait for the next actual sender-clock second, rather than pretending an
    // old JD header arrived after Start. All recorded sender intervals remain
    // exact, including the photo 97 seconds before this independent question.
    await until(() async {
      final now = DateTime.now().toUtc();
      return DateTime.utc(
              now.year, now.month, now.day, now.hour, now.minute, now.second)
          .isAfter(db.automationSessionStartedAt!);
    }, stage: 'live sender clock');
    final now = DateTime.now().toUtc();
    questionAt = DateTime.utc(
        now.year, now.month, now.day, now.hour, now.minute, now.second);
    clockShift = questionAt.difference(DateTime.utc(2026, 11, 10, 2, 26, 53));
    // The exact known image is permitted fixture context. Only the target ?
    // must be discovered and admitted by CaptureHome itself.
    await query(() async {
      oldPhotoId = 'v46-existing-current-photo23';
      final values = await snapshot('question');
      final inspection = OcrInspection.fromMap(shiftedOcr('question', values));
      // Seed the same physical candidate that CaptureHome registers below.
      // A raw native inner rectangle in this same evidence is a different
      // observation key from the recovered full bubble, so it cannot stand in
      // for an already bound production frontier when AX polling arrives later.
      const selector = OcrImageCandidateSelector();
      final extraction = const OcrCaptureExtractor().analyze(inspection);
      final selected = selector.select(inspection, _customer,
          allowUnlabeledLatestImage: true,
          includeTextDense: true,
          customerText:
              (extraction.capture?.messages ?? const <CapturedMessage>[])
                  .where((message) =>
                      message.direction == 'incoming' && message.media.isEmpty)
                  .map((message) => message.body));
      final cards = selector.recoverCustomerBlocks(inspection, _customer,
          owned: selected,
          hasPinnedImage:
              ViewportEvidence(values).pinnedMedia?['kind'] == 'image');
      expect(cards, hasLength(1));
      final photo = cards.single;
      expect(photo.width, greaterThan(.3),
          reason:
              'Use the real recovered bubble, not its narrow native sub-ROI.');
      final inventory = CustomerMediaInventory(db);
      final knownReceivedAt = DateTime.fromMillisecondsSinceEpoch(
          (values['capturedAtMs']! as int) - 1,
          isUtc: true);
      expect(knownReceivedAt.isBefore(db.automationSessionStartedAt!), isFalse);
      final receipt = await inventory.observe(
          customer: _customer,
          evidenceId: values['evidenceId']! as String,
          observedAt: knownReceivedAt,
          senderAt: questionAt.subtract(const Duration(seconds: 97)),
          slot: 0,
          region: [photo.x, photo.y, photo.width, photo.height],
          current: true,
          occurrenceKey: 'fixture-known-live-photo23');
      await db.admitMediaMessage(_customer,
          receiptId: receipt,
          evidenceId: values['evidenceId']! as String,
          occurrenceKey: 'fixture-known-live-photo23',
          receivedAt: knownReceivedAt,
          senderAt: questionAt.subtract(const Duration(seconds: 97)),
          messageId: oldPhotoId);
      await inventory.classify(receipt, 'image');
      final audit = MediaCaptureAudit(db, record: (_, __) {});
      final observation = await audit.discover(ViewportEvidence(values), photo,
          inspection: inspection, physicalCards: [photo]);
      await audit.bindParent(observation,
          receiptId: receipt, messageId: oldPhotoId!);
    });
    phase = 'question';
    await until(() async => refineEntered, stage: 'registered unknown decode');
    final before = await work();
    expect(before, hasLength(2));
    final unknown = before.where((r) => r['message_id'] != oldPhotoId).single;
    questionId = unknown['message_id']! as String;
    expect(unknown['input_kind'], 'media');
    expect(unknown['response_state'], 'pending');
    final registered = await query(() async => (await db.database).query(
        'customer_media_items',
        where: 'customer=? AND message_id=?',
        whereArgs: [_customer, questionId]));
    expect(registered.single['kind'], 'unknown');
    expect(registered.single['media_json'], '[]');
    expect(generated, isEmpty);
    expect(formal, isEmpty,
        reason: 'Unreadable content cannot be marked formally answered.');
    expect(busyReturned, isTrue);
    expect(refinementRequests, greaterThanOrEqualTo(2),
        reason: 'Busy is retryable, never a cached successful empty decode.');
    final late = await query(() => snapshot('late-old'));
    await query(() => CaptureEvidenceStore(db).record(ViewportEvidence(late)));
    await until(() async => lateEntered, stage: 'old OCR in flight');
    refineGate.complete();
    await until(() async => formal.isNotEmpty, stage: 'same-owner formal send');
    await until(
        () async => (await work()).any((r) =>
            r['message_id'] == questionId && r['response_state'] == 'answered'),
        stage: 'native receipt coverage');
    expect(lateCompleted, isFalse,
        reason: 'Formal delivery must not depend on this older OCR callback.');
    final completed = await work();
    expect(completed, hasLength(2));
    final answer = completed.singleWhere((r) => r['message_id'] == questionId);
    expect(answer['input_kind'], 'text');
    expect(answer['answered_attempt_id'], isNotNull);
    expect(answer['activated_at_ms'], unknown['activated_at_ms']);
    expect(
        completed.singleWhere(
            (r) => r['message_id'] == oldPhotoId)['response_state'],
        'pending');
    expect(generated, hasLength(1));
    expect(formal, [_reply]);
    lateOcrGate.complete();
    await until(() async => lateCompleted, stage: 'late OCR released');
    phase = 'question-repeat';
    final repeat = await query(() => snapshot('question-repeat'));
    await query(
        () => CaptureEvidenceStore(db).record(ViewportEvidence(repeat)));
    await until(() async => (inspected['question-repeat'] ?? 0) > 0,
        stage: 'subsequent reread');
    await tick(count: 40);
    final finalWork = await work();
    expect(finalWork, hasLength(2));
    expect(
        finalWork.singleWhere(
            (r) => r['message_id'] == oldPhotoId)['response_state'],
        'pending');
    expect(
        finalWork.singleWhere(
            (r) => r['message_id'] == questionId)['answered_attempt_id'],
        answer['answered_attempt_id']);
    expect(generated, hasLength(1));
    expect(formal, [_reply]);
    final history = await query(() async => (await db.history).read(_customer));
    final questions = (history!['messages'] as List)
        .whereType<Map>()
        .where((m) => m['direction'] == 'incoming' && m['body'] == '？')
        .toList();
    expect(questions, hasLength(1));
    expect(questions.single['id'], questionId);
    expect(tester.takeException(), isNull);
    await shutdown();
  });
}
