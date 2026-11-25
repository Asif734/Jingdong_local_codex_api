import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/main.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

import 'helpers/run_permissions.dart';

void main() {
  for (final restart in [false, true]) {
    testWidgets(
        restart
            ? 'CaptureHome old stopped OCR cannot release a promoted new-run lease'
            : 'CaptureHome promotes held same-frame OCR with one native recognition and one registration',
        (tester) async {
      const customer = 'jd_promotion_test';
      final channel = MethodChannel('jd-v44-promotion-$restart');
      late Directory root;
      late CaptureDatabase db;
      var phase = 'baseline';
      var red = false;
      final gates = <String, Completer<void>>{};
      final inspections = <String, int>{};
      final stamps = <String, int>{};
      final snapshots = <String, Map<String, Object?>>{};
      final scheduled = <String>[];
      final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=');
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('jd_v44_home_promotion_');
        db = CaptureDatabase(storageRoot: root);
      });
      tester.view.physicalSize = const Size(1300, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() {
        for (final gate in gates.values) {
          if (!gate.isCompleted) gate.complete();
        }
      });

      Future<Map<String, Object?>> snapshot(String kind) async {
        final session = db.currentAutomationSessionId!;
        final id = '$kind-$session';
        if (snapshots[id] case final existing?) return existing;
        final directory =
            await Directory('${root.path}/capture_evidence').create();
        final image = await File('${directory.path}/$id.png').writeAsBytes(png);
        final manifest = File('${directory.path}/$id.json');
        final stamp =
            stamps.putIfAbsent(id, () => DateTime.now().millisecondsSinceEpoch);
        final raw = <String, Object?>{
          'evidenceId': id,
          'customer': customer,
          'automationSessionId': session,
          'capturedAtMs': stamp,
          'windowId': 1,
          'imageWidth': 1000,
          'imageHeight': 1000,
          'imagePath': image.path,
          'manifestPath': manifest.path,
          'pngSHA256': sha256.convert(png).toString(),
          'chatContentSHA256': 'immutable:$id',
          'chatRegion': {'left': .24, 'right': .75, 'top': .2, 'bottom': .79},
        };
        await manifest.writeAsString(jsonEncode(raw));
        snapshots[id] = raw;
        return raw;
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
              {
                'customer': customer,
                'identitySource': 'ax',
                'unread': false,
                'redClockPresent': red,
                'evidenceAvailable': true,
                'unreadEvidence': 0,
              }
            ];
          case 'openConversation':
            return {'opened': true, 'customer': customer};
          case 'scrollConversation':
            return {'scrolled': true};
          case 'recentMediaCacheRevision':
            return {'revision': 'no-media'};
          case 'captureRecentCachedMedia':
            return {'kind': 'none'};
          case 'captureViewportEvidence':
            return snapshot(phase);
          case 'inspectViewportEvidence':
            final metadata = jsonDecode(
                    await File(args['manifestPath']! as String).readAsString())
                as Map;
            final id = metadata['evidenceId']! as String;
            inspections.update(id, (value) => value + 1, ifAbsent: () => 1);
            if (gates[id] case final gate?) await gate.future;
            final at = DateTime.fromMillisecondsSinceEpoch(
                    metadata['capturedAtMs']! as int,
                    isUtc: true)
                .add(const Duration(hours: 8));
            final clock =
                '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
            return {
              'activeCustomerId': customer,
              'windowId': 1,
              'imageWidth': 1000,
              'imageHeight': 1000,
              'capturedAtMs': metadata['capturedAtMs'],
              'pngBase64': base64Encode(png),
              'chatRegion': metadata['chatRegion'],
              'observations': [
                if (id.startsWith('target-')) ...[
                  {
                    'text': '$customer $clock',
                    'confidence': 1.0,
                    'x': .27,
                    'y': .30,
                    'width': .30,
                    'height': .018
                  },
                  {
                    'text': 'How do I connect the USB cable?',
                    'confidence': 1.0,
                    'x': .28,
                    'y': .35,
                    'width': .30,
                    'height': .02
                  },
                ],
              ],
              'visualRegions': <Object>[],
            };
          case 'sendDraftOnce':
            fail('This capture-ownership test never sends a customer message.');
        }
        return <String, Object?>{};
      });

      Future<void> tick([int steps = 1]) async {
        for (var i = 0; i < steps; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
        }
      }

      Future<void> until(bool Function() ready) async {
        for (var i = 0; i < 900 && !ready(); i++) {
          await tick();
        }
        expect(ready(), isTrue,
            reason: 'phase=$phase red=$red inspections=$inspections');
      }

      Future<T> query<T>(Future<T> Function() read) async {
        T? value;
        Object? error;
        var done = false;
        await tester.runAsync(() async {
          unawaited(read().then((result) {
            value = result;
            done = true;
          }, onError: (Object failure) {
            error = failure;
            done = true;
          }));
        });
        await until(() => done);
        if (error != null) throw error!;
        return value as T;
      }

      Future<Map<String, Object?>> stored(String id) =>
          query(() async => (await (await db.database)
                  .query('capture_evidence', where: 'id=?', whereArgs: [id]))
              .single);
      Future<List<Map<String, Object?>>> work(String run) => query(() async =>
          (await (await db.database).query('automation_session_messages',
              where: 'session_id=? AND user_id=?',
              whereArgs: [run, customer])));
      Future<void> start() async {
        await tester.runAsync(() => tester.tap(find.text('Start automation')));
        await until(() => db.currentAutomationSessionId != null);
        final id = 'baseline-${db.currentAutomationSessionId}';
        await until(() => (inspections[id] ?? 0) > 0);
        await tick(25);
      }

      Future<({String id, String token, String run})> holdAndPromote() async {
        final raw = await query(() => snapshot('target'));
        final evidence = ViewportEvidence({
          ...raw,
          'capturePurpose': 'arrival_observation',
          'replyActivationAllowed': false,
        });
        final id = evidence.id;
        gates[id] = Completer<void>();
        await query(() => CaptureEvidenceStore(db).record(evidence));
        phase = 'target';
        await until(() => (inspections[id] ?? 0) > 0);
        final before =
            ViewportEvidence.fromJson((await stored(id))['payload']! as String);
        final token = before.metadata['captureClaimToken']! as String;
        red = true;
        var promoted = false;
        for (var i = 0; i < 300 && !promoted; i++) {
          final row = await stored(id);
          final current = ViewportEvidence.fromJson(row['payload']! as String);
          promoted = current.metadata['capturePurpose'] == 'live_signal' &&
              current.metadata['replyActivationAllowed'] == true;
          if (promoted) {
            expect(row['state'], 'processing');
            expect(current.metadata['captureClaimToken'], token);
          } else {
            await tick();
          }
        }
        expect(promoted, isTrue);
        expect(inspections[id], 1);
        expect(await work(db.currentAutomationSessionId!), isEmpty);
        return (id: id, token: token, run: db.currentAutomationSessionId!);
      }

      await tester.pumpWidget(MaterialApp(
          home: CaptureHome(
              database: db,
              adapter: MacOSCaptureAdapter(channel: channel),
              scanIntervalOverride: const Duration(milliseconds: 100),
              draftSchedulerOverride: scheduled.add)));
      await grantRunPermissions(tester);
      await start();
      final original = await holdAndPromote();
      var current = original;
      if (restart) {
        red = false;
        phase = 'baseline';
        await tester.runAsync(() => tester.tap(find.text('Stop automation')));
        await until(() =>
            find.text('Start automation').evaluate().isNotEmpty &&
            tester
                    .widget<FilledButton>(
                        find.widgetWithText(FilledButton, 'Start automation'))
                    .onPressed !=
                null);
        final previousRun = original.run;
        await tester.runAsync(() => tester.tap(find.text('Start automation')));
        await until(() => db.currentAutomationSessionId != previousRun);
        await until(() =>
            (inspections['baseline-${db.currentAutomationSessionId}'] ?? 0) >
            0);
        await tick(25);
        current = await holdAndPromote();
        gates[original.id]!.complete();
        await tick(30);
        expect((await stored(original.id))['state'], 'session_archived');
        final active = await stored(current.id);
        expect(active['state'], 'processing');
        expect(
            ViewportEvidence.fromJson(active['payload']! as String)
                .metadata['captureClaimToken'],
            current.token);
        expect(await work(previousRun), isEmpty);
        expect(await work(current.run), isEmpty);
      }
      gates[current.id]!.complete();
      var inputs = <Map<String, Object?>>[];
      for (var i = 0; i < 500 && inputs.isEmpty; i++) {
        inputs = await work(current.run);
        if (inputs.isEmpty) await tick();
      }
      expect(inputs, hasLength(1));
      await tick(35);
      final finished = await stored(current.id);
      expect(finished['state'], 'processed');
      expect(
          ViewportEvidence.fromJson(finished['payload']! as String)
              .metadata['captureCompletedClaimToken'],
          current.token);
      expect(inspections[current.id], 1);
      expect(scheduled, isNotEmpty);
      final sidecar =
          File('${snapshots[current.id]!['manifestPath']}.ocr.json');
      final saved = await query(
          () async => jsonDecode(await sidecar.readAsString()) as Map);
      expect(saved['evidenceId'], current.id);
      expect(saved['activeCustomerId'], customer);
      expect(await work(current.run), hasLength(1));
      red = false;
      await tester.runAsync(() => tester.tap(find.text('Stop automation')));
      await tick(20);
      await tester.pumpWidget(const SizedBox());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await tester.runAsync(() async {
        await db.close();
        await root.delete(recursive: true);
      });
    });
  }
}
