import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_text_refinement.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/runtime/delivery_timing.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';

AiDraft _reply(String text, {List<String>? formalIds}) => AiDraft.fromJson({
      'reply': text,
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'auto_send_allowed': false,
      'reply_purpose': 'substantive',
      'reply_media_dependency_keys': <String, String>{},
      'model': 'controlled-v43-text-refinement',
      if (formalIds != null) 'formal_response_message_ids': formalIds,
    }, mediaBaseUrl: Uri());

void main() {
  group('conservative OCR text refinement', () {
    test('result-clause nominalizer is local, symmetric and topic independent',
        () {
      for (final pair in [
        ('不管选横向还是纵向，打印出来都是纵向', '不管选横向还是纵向，打印出来的都是纵向'),
        ('测量出来都是12.5mm', '测量出来的都是12.5mm'),
      ]) {
        expect(OcrTextRefinement.classify(pair.$1, pair.$2),
            OcrTextChange.equivalent);
        expect(OcrTextRefinement.classify(pair.$2, pair.$1),
            OcrTextChange.equivalent);
      }
    });

    test('edge stitching needs exact original words and cannot replace facts',
        () {
      expect(
          OcrTextRefinement.isViewportFragment(
              'not finding the machine', 'am not finding'),
          isTrue);
      expect(
          OcrTextRefinement.isViewportFragment(
              'not finding the machine', 'I am not finding'),
          isTrue);
      for (final pair in [
        ('not finding the machine', 'am finding the machine'),
        ('not finding model M880', 'am not finding model M888'),
        ('print width 12.5mm', 'am print width 125mm'),
        ('print in landscape mode', 'am print in portrait mode'),
      ]) {
        expect(OcrTextRefinement.isViewportFragment(pair.$1, pair.$2), isFalse);
        expect(OcrTextRefinement.classify(pair.$1, pair.$2),
            OcrTextChange.material);
      }
    });

    for (final pair in [
      ('打印机型号是M880，请帮我设置', '打印机型号是M888，请帮我设置'),
      ('打印宽度需要12.5mm', '打印宽度需要125mm'),
      ('打印宽度需要200mm', '打印宽度需要20mm'),
      ('请不要打开打印机电源', '请打开打印机电源'),
      ('打印出来都是横向', '打印出来的都是纵向'),
      ('先装纸再开电源', '先开电源再装纸'),
      ('这个打印机是我的', '这个打印机是我'),
      ('我是小王的', '我是小王'),
      ('I need model M880', 'I need model M 880'),
      ('打印出来都是黑的', '打印出来的都不是黑的'),
    ]) {
      test('cannot erase meaningful correction ${pair.$1} -> ${pair.$2}', () {
        expect(OcrTextRefinement.classify(pair.$1, pair.$2),
            OcrTextChange.material);
      });
    }
  });

  group('durable message refinement and exact receive timing', () {
    late Directory root;
    late CaptureDatabase db;
    late Map<String, dynamic> recorded;
    const customer = 'jd_mbnrscuhukvy';
    final firstAt = DateTime.parse('2026-11-09T03:50:32.468Z');
    final refinedAt = DateTime.parse('2026-11-09T03:50:45.729Z');
    final senderAt = DateTime.parse('2026-11-09T03:50:24Z');

    setUp(() async {
      root = await Directory.systemTemp.createTemp('jd_v43_refinement_');
      db = CaptureDatabase(storageRoot: root);
      await db.beginAutomationSession(
          startedAt: firstAt.subtract(const Duration(minutes: 1)));
      recorded = jsonDecode(await File(
              'test/fixtures/v43_ocr_refinement/recorded-v41-refinement.json')
          .readAsString()) as Map<String, dynamic>;
    });
    tearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });

    CapturedMessage message(String id, String body,
            {DateTime? sentAt, String? bubble, String? evidence}) =>
        CapturedMessage(
            stableId: id,
            direction: 'incoming',
            body: body,
            sender: customer,
            sentAt: sentAt ?? senderAt,
            axPath: 'recorded/customer-owned text bubble',
            observationTurnKey: bubble,
            captureEvidenceId: evidence);

    Future<int> capture(List<CapturedMessage> messages, DateTime at,
            {bool current = true}) =>
        db.saveCapture(
            CapturedConversation(
                stableKey: customer,
                customerName: customer,
                customerExternalId: customer,
                automationSessionId: db.currentAutomationSessionId,
                capturedAt: at,
                messages: messages),
            isCurrentViewport: current);

    Future<List<Map>> incoming() async =>
        ((await (await db.history).read(customer))!['messages'] as List)
            .cast<Map>()
            .where((m) => m['direction'] == 'incoming')
            .toList();

    Future<String> begin(String id) async => (await db.beginGeneration(
        customer: customer,
        pendingId: (await db.conversation(customer))!.id,
        batchEndMessageId: id))!;

    Future<int> save(String id, String token, AiDraft draft,
        {bool prepare = true}) async {
      final ready =
          prepare ? await db.prepareAutomaticDraft(customer, draft) : draft;
      return db.saveDraft((await db.conversation(customer))!.id, ready,
          expectedMessageId: id,
          expectedUserId: customer,
          generationToken: token);
    }

    Future<void> submit(String reply) async {
      final attempt =
          await db.beginDeliveryAttempt(userId: customer, reply: reply);
      final now = DateTime.now().millisecondsSinceEpoch;
      await File(attempt['receiptPath']!).writeAsString(jsonEncode({
        'attemptId': attempt['attemptId'],
        'customer': customer,
        'state': 'submitted',
        'sendClickedAtMs': now,
        'timeMs': now,
      }));
      await db.recoverDeliveryReceipts();
    }

    test(
        'recorded v41 18-to-19 reading during generation saves the first reply',
        () async {
      final original = recorded['first'] as Map;
      final refined = recorded['refined'] as Map;
      final id = original['id']! as String;
      expect((original['body']! as String).length, 18);
      expect((refined['body']! as String).length, 19);
      await capture([
        message(id, original['body']! as String,
            bubble: original['observation_turn_key']! as String,
            evidence: original['capture_evidence_id']! as String)
      ], firstAt);
      final pendingId = (await db.conversation(customer))!.id;
      final token = await begin(id);
      var generatorCalls = 0;
      final generating = Completer<void>();
      final release = Completer<void>();
      const reply = '请将软件和驱动中的打印方向都设为横向，再试打一张。';
      Future<int> generateAndSave() async {
        generatorCalls++;
        final input = await db.generationMessages(customer);
        expect(input.single['body'], original['body']);
        generating.complete();
        await release.future;
        expect(
            await db.generationInputsAnalysisReady(customer,
                generationToken: token),
            isTrue);
        return save(id, token, _reply(reply));
      }

      final pendingResult = generateAndSave();
      await generating.future;
      await capture([
        message(recorded['refinedObservationId']! as String,
            refined['body']! as String,
            // This later saved frame carries the same sender clock. Its
            // observation key is distinct, as in the recorded live reread.
            bubble: 'ocr-bubble:${refinedAt.millisecondsSinceEpoch}:later:0',
            evidence: refined['capture_evidence_id']! as String)
      ], refinedAt);
      final observed = (await incoming()).single;
      expect(observed['id'], id);
      expect(observed['body'], original['body']);
      expect(observed['captured_at'], firstAt.toIso8601String());
      expect(observed['last_observed_at'], refinedAt.toIso8601String());
      expect(observed['service_evidence_revision'], 0);
      expect(
          (observed['ocr_variants'] as List).cast<Map>().map((r) => r['body']),
          containsAll([original['body'], refined['body']]));
      final work =
          await (await db.database).query('automation_session_messages');
      expect(work, hasLength(1));
      expect(work.single['work_revision'], 0);
      expect(work.single['input_key'],
          ConversationFileStore.materialInputKey(observed));
      expect(work.single['activated_at_ms'], firstAt.millisecondsSinceEpoch);
      release.complete();
      expect(await pendingResult, 1);
      expect(generatorCalls, 1);
      // saveDraft transfers ownership from pending_customers to the durable
      // delivery queue; only a positive native receipt may complete the work.
      expect(await db.isMessageFormallyAnswered(customer, id), isFalse);
      expect(
          (await (await db.database).query('automation_session_messages'))
              .single['response_state'],
          'pending');
      expect(await db.hasUndeliveredDraft(customer), isTrue);
      final delivery = (await db.nextReadyDelivery())!;
      expect(delivery.taskId, token);
      expect(delivery.draft.reply, reply);
      expect(
          await db.beginGeneration(
              customer: customer, pendingId: pendingId, batchEndMessageId: id),
          isNull);
      await submit(reply);
      expect(await db.isMessageFormallyAnswered(customer, id), isTrue);
      expect(await db.hasPendingUnanswered(customer), isFalse);
      expect(
          await (await db.database).query('delivery_attempts'), hasLength(1));
    });

    test('immutable ledger timing survives historical captured_at overwrite',
        () async {
      await capture(
          [message('question', 'Please help configure model M880.')], firstAt);
      final token = await begin('question');
      expect(
          await save('question', token, _reply('Select the M880 driver.')), 1);
      // Replay an existing v41 history file after its later OCR overwritten
      // timestamp. The repaired metric must use durable message ownership.
      final store = await db.history;
      final history = (await store.read(customer))!;
      (history['messages'] as List).cast<Map>().single['captured_at'] =
          refinedAt.toIso8601String();
      await File(
              '${store.conversationsDirectory.path}/${store.safeUserId(customer)}.json')
          .writeAsString(jsonEncode(history));
      final timing = await db.deliveryTiming(customer, token);
      expect(timing['firstObservedAt'], firstAt.toIso8601String());
      expect(timing['firstObservedSource'], 'message_work_activation');
      final click = DateTime.parse(recorded['nativeClickUtc']! as String);
      final measured = formalReplyTiming(timing,
          clickedAt: click, confirmedAt: click.add(const Duration(seconds: 1)));
      expect(measured['firstObservedToClickMs'], 57853);
      expect(click.difference(refinedAt).inMilliseconds, 44592);
    });

    test(
        'later clipped frame cannot replace a complete in-flight or ready input',
        () async {
      final original = recorded['first'] as Map;
      final id = original['id']! as String;
      final full = original['body']! as String;
      final source = original['capture_evidence_id']! as String;
      final turn = original['observation_turn_key']! as String;
      await capture(
          [message(id, full, bubble: turn, evidence: source)], firstAt);
      final token = await begin(id);
      final release = Completer<void>();
      final generating = Completer<void>();
      const reply = '请同时检查软件和驱动的打印方向设置。';
      final result = () async {
        expect((await db.generationMessages(customer)).single['body'], full);
        generating.complete();
        await release.future;
        expect(
            await db.generationInputVersionsCurrent(customer,
                generationToken: token),
            isTrue);
        return save(id, token, _reply(reply));
      }();
      await generating.future;
      await capture([
        message('clipped-later-frame', '打印出来都是纵向',
            bubble: 'ocr-bubble:later-scrolled-frame:0',
            evidence: 'different-scrolled-frame')
      ], refinedAt);
      var record = (await incoming()).single;
      expect(record['body'], full);
      expect(record['service_evidence_revision'], 0);
      expect(record['text_source_evidence_id'], source);
      expect(record['text_source_observation_turn_key'], turn);
      expect(record['last_observed_at'], refinedAt.toIso8601String());
      release.complete();
      expect(await result, 1);
      await capture([
        message('clipped-again-after-generation', '都是纵向',
            bubble: 'ocr-bubble:another-scrolled-frame:0',
            evidence: 'another-scrolled-frame')
      ], refinedAt.add(const Duration(seconds: 1)));
      record = (await incoming()).single;
      expect(record['body'], full);
      expect(record['service_evidence_revision'], 0);
      expect(record['captured_at'], firstAt.toIso8601String());
      final ready = (await db.nextReadyDelivery())!;
      expect(ready.taskId, token);
      expect(ready.draft.reply, reply);
      expect(await (await db.database).query('automation_session_messages'),
          hasLength(1));
      await submit(reply);
      expect(await db.isMessageFormallyAnswered(customer, id), isTrue);
    });

    test('explicit same frozen-source proof still accepts a shorter correction',
        () async {
      // This pair is explicit upstream attribution to one immutable slot,
      // rather than inferred from a sender second or substring similarity.
      // Normal extractor keys may differ with body hashes and do not supply
      // this proof just because two scans report the same sender time.
      const turn = 'ocr-bubble:explicit-immutable-slot:0';
      const evidence = 'one-explicit-immutable-source';
      await capture(
          [message('first-reading', '不要开机', bubble: turn, evidence: evidence)],
          firstAt);
      final token = await begin('first-reading');
      await capture([
        message('confirmed-correction', '开机', bubble: turn, evidence: evidence)
      ], refinedAt);
      final record = (await incoming()).single;
      expect(record['body'], '开机');
      expect(record['service_evidence_revision'], 1);
      expect(
          await db.generationInputVersionsCurrent(customer,
              generationToken: token),
          isFalse);
      expect(await save('first-reading', token, _reply('Old answer.')), 0);
      expect(await db.hasPendingUnanswered(customer), isTrue);
    });

    test(
        'edge-stitched OCR fragment leaves the complete pending question intact',
        () async {
      await capture([
        message('original-problem', 'not finding the machine',
            bubble: 'ocr-bubble:complete-frame:0', evidence: 'complete-frame')
      ], firstAt);
      final token = await begin('original-problem');
      final changed = await capture([
        message('edge-stitched-reading', 'am not finding',
            bubble: 'ocr-bubble:clipped-frame:0', evidence: 'clipped-frame')
      ], refinedAt);
      expect(changed, 0);
      final kept = (await incoming()).single;
      expect(kept['body'], 'not finding the machine');
      expect(kept['service_evidence_revision'], 0);
      expect(
          await db.generationInputVersionsCurrent(customer,
              generationToken: token),
          isTrue);
      const reply = 'Please check the Bluetooth and location permissions.';
      expect(await save('original-problem', token, _reply(reply)), 1);
      final ready = (await db.nextReadyDelivery())!;
      expect(ready.taskId, token);
      expect(ready.draft.reply, reply);
    });

    test('legacy mixed latest-frame and first-turn fields are not exact proof',
        () async {
      const turn = 'ocr-bubble:first-frame:0';
      await capture([
        message('legacy-full', '请不要开机',
            bubble: turn, evidence: 'original-full-frame')
      ], firstAt);
      final store = await db.history;
      final history = (await store.read(customer))!;
      final old = (history['messages'] as List).cast<Map>().single;
      old.remove('text_source_evidence_id');
      old.remove('text_source_observation_turn_key');
      old['capture_evidence_id'] = 'latest-clipped-frame';
      await File(
              '${store.conversationsDirectory.path}/${store.safeUserId(customer)}.json')
          .writeAsString(jsonEncode(history));
      final token = await begin('legacy-full');
      await capture([
        message('clipped-legacy-reread', '开机',
            bubble: turn, evidence: 'latest-clipped-frame')
      ], refinedAt);
      final kept = (await incoming()).single;
      expect(kept['body'], '请不要开机');
      expect(kept['service_evidence_revision'], 0);
      expect(kept['text_source_evidence_id'], isNull);
      expect(kept['text_source_observation_turn_key'], isNull);
      expect(
          await db.generationInputVersionsCurrent(customer,
              generationToken: token),
          isTrue);
    });

    for (final pair in [
      ('打印机型号是M880，请帮我设置', '打印机型号是M888，请帮我设置'),
      ('打印宽度需要200mm才合适', '打印宽度需要20mm才合适'),
      ('请不要打开打印机电源', '请打开打印机电源'),
      ('请将打印方向设置为横向', '请将打印方向设置为纵向'),
      ('先装纸再开电源', '先开电源再装纸'),
    ]) {
      test('material correction keeps pending and rejects old draft ${pair.$2}',
          () async {
        await capture([
          message('first-reading', pair.$1, bubble: 'ocr-bubble:frozen-frame:0')
        ], firstAt);
        final token = await begin('first-reading');
        final changed = await capture([
          message('corrected-reading', pair.$2,
              bubble: 'ocr-bubble:frozen-frame:0')
        ], refinedAt);
        expect(changed, 0,
            reason: 'A revised reading is not another received message');
        expect((await incoming()).single['body'], pair.$2);
        expect((await incoming()).single['captured_at'],
            firstAt.toIso8601String());
        expect(
            await db.generationInputVersionsCurrent(customer,
                generationToken: token),
            isFalse);
        expect(await save('first-reading', token, _reply('Old answer.')), 0);
        expect(await db.hasPendingUnanswered(customer), isTrue);
        expect(await (await db.database).query('generated_drafts'), isEmpty);
        await db.abandonGeneration(customer, token);
        final next = await begin('first-reading');
        expect((await db.generationMessages(customer)).single['body'], pair.$2);
        expect(
            await save('first-reading', next, _reply('Corrected answer.')), 1);
        final revision =
            (await (await db.database).query('automation_session_messages'))
                .single['work_revision'];
        await capture([
          message('first-reading', pair.$1, bubble: 'ocr-bubble:frozen-frame:0')
        ], firstAt, current: false);
        expect((await incoming()).single['body'], pair.$2);
        expect(
            (await (await db.database).query('automation_session_messages'))
                .single['work_revision'],
            revision);
      });
    }

    test('batch timing uses only formally covered message activations',
        () async {
      final unrelatedAt = firstAt.subtract(const Duration(seconds: 20));
      await capture([
        message('unrelated-old', 'Old separate question.',
            sentAt: unrelatedAt, bubble: 'ocr-bubble:unrelated:0')
      ], unrelatedAt);
      await capture([
        message('one', 'First current problem.', bubble: 'ocr-bubble:one:0')
      ], firstAt);
      await capture([
        message('two', 'Second current problem.',
            sentAt: refinedAt, bubble: 'ocr-bubble:two:0')
      ], refinedAt);
      final token = await begin('two');
      expect(
          await save(
              'two',
              token,
              _reply('The answer covers the two current problems.',
                  formalIds: ['one', 'two']),
              prepare: false),
          1);
      final timing = await db.deliveryTiming(customer, token);
      expect(timing['firstObservedAt'], firstAt.toIso8601String());
      expect(timing['receivedAtByMessage'], {
        'one': firstAt.toIso8601String(),
        'two': refinedAt.toIso8601String(),
      });
      expect(timing['queuedAtMs'], unrelatedAt.millisecondsSinceEpoch);
      await submit('The answer covers the two current problems.');
      expect(await db.isMessageFormallyAnswered(customer, 'one'), isTrue);
      expect(await db.isMessageFormallyAnswered(customer, 'two'), isTrue);
      expect(await db.isMessageFormallyAnswered(customer, 'unrelated-old'),
          isFalse);
    });

    test('two visible same-second text bubbles keep independent work',
        () async {
      await capture([
        message('first', '打印出来都是纵向', bubble: 'ocr-bubble:same-frame:0'),
        message('second', '打印出来的都是纵向', bubble: 'ocr-bubble:same-frame:1'),
      ], firstAt);
      expect(await incoming(), hasLength(2));
      final work =
          await (await db.database).query('automation_session_messages');
      expect(
          work.map((r) => r['message_id']), containsAll(['first', 'second']));
      expect(work.every((r) => r['response_state'] == 'pending'), isTrue);
    });

    test('same media asset path does not merge two admitted message parents',
        () async {
      final inventory = CustomerMediaInventory(db);
      for (var i = 0; i < 2; i++) {
        final at = firstAt.add(Duration(seconds: i));
        final receipt = await inventory.observe(
            customer: customer,
            evidenceId: 'separate-image-$i',
            observedAt: at,
            senderAt: senderAt,
            slot: i,
            region: [.3, .3 + i * .2, .1, .1],
            current: true,
            occurrenceKey: 'separate-real-image-$i');
        final admission = await db.admitMediaMessage(customer,
            receiptId: receipt,
            evidenceId: 'separate-image-$i',
            occurrenceKey: 'separate-real-image-$i',
            receivedAt: at,
            senderAt: senderAt,
            messageId: 'image-$i');
        await capture([
          CapturedMessage(
              stableId: admission.messageId,
              direction: 'incoming',
              body: '[Customer sent an image]',
              sender: customer,
              sentAt: senderAt,
              axPath: 'independent physical image bubble $i',
              mediaReceiptId: admission.receiptId,
              media: const [
                CapturedMedia(type: 'image', path: '/same/reused/original.png')
              ])
        ], at);
      }
      final records = await incoming();
      expect(records, hasLength(2));
      expect(records.map((r) => r['id']), containsAll(['image-0', 'image-1']));
      expect(records.map((r) => r['media_receipt_id']).toSet(), hasLength(2));
      expect(await (await db.database).query('automation_session_messages'),
          hasLength(2));
    });
  });
}
