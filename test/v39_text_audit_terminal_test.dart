import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late CustomerMediaInventory inventory;
  late MediaCaptureAudit audit;
  late String session;
  late DateTime received;
  const region =
      OcrVisualRegion(x: .24, y: .70, width: .42, height: .08, confidence: 0);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v39_audit_terminal_');
    db = CaptureDatabase(storageRoot: root);
    received = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch - 1000,
        isUtc: true);
    session = await db.beginAutomationSession(
        startedAt: received.subtract(const Duration(seconds: 10)));
    inventory = CustomerMediaInventory(db);
    audit = MediaCaptureAudit(db);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<({String parent, String receipt, String observation})> admit(
      String key) async {
    final evidenceId = 'clipped-$key';
    final receipt = await inventory.observe(
        customer: 'buyer',
        evidenceId: evidenceId,
        occurrenceKey: key,
        observedAt: received,
        senderAt: received.subtract(const Duration(seconds: 1)),
        slot: 0,
        region: [region.x, region.y, region.width, region.height],
        current: true);
    final parent = await db.admitMediaMessage('buyer',
        receiptId: receipt,
        evidenceId: evidenceId,
        occurrenceKey: key,
        receivedAt: received,
        senderAt: received.subtract(const Duration(seconds: 1)),
        messageId: 'incoming-media:$key');
    final observation = await audit.discover(
        ViewportEvidence({
          'evidenceId': evidenceId,
          'customer': 'buyer',
          'automationSessionId': session,
          'capturedAtMs': received.millisecondsSinceEpoch,
          'imagePath': '${root.path}/$evidenceId.png',
          'manifestPath': '${root.path}/$evidenceId.json',
        }),
        region);
    await audit.bindParent(observation,
        receiptId: parent.receiptId, messageId: parent.messageId);
    return (
      parent: parent.messageId,
      receipt: parent.receiptId,
      observation: observation
    );
  }

  Future<void> clarify(
      ({String parent, String receipt, String observation}) item) async {
    expect(
        await db.clarifyUnknownMessageAsText('buyer',
            parentMessageId: item.parent,
            receiptId: item.receipt,
            text: CapturedMessage(
                stableId: 'ocr:clear-${item.parent}',
                direction: 'incoming',
                sender: 'buyer',
                body: 'can you share me a video?',
                sentAt: received.subtract(const Duration(seconds: 1)),
                axPath: 'same-bubble-text-proof',
                captureEvidenceId: 'full-frame'),
            evidenceId: 'full-frame',
            expectedSessionId: session),
        item.parent);
  }

  Future<Map<String, Object?>> observation(String id) async =>
      (await (await db.database).query('media_capture_audit',
              where: 'observation_id=?', whereArgs: [id]))
          .single;

  test('a clarified text audit cannot reopen on late native or model results',
      () async {
    final item = await admit('tutorial-request');
    await clarify(item);
    await audit.confirmTextParent('buyer',
        parentMessageId: item.parent,
        receiptId: item.receipt,
        expectedSessionId: session);
    final confirmed = await observation(item.observation);
    final details = jsonDecode(confirmed['details']! as String) as Map;
    expect(confirmed['state'], 'rejected_text');
    expect(details['reason'], 'same_bubble_clarified_as_customer_text');
    expect(details['parentMessageId'], item.parent);
    expect(details['resolvedMessageId'], item.parent);
    expect(details['mediaReceiptId'], item.receipt);

    for (final state in [
      'rejected_text',
      'unverified',
      'image_partial',
      'video_preview_only',
      'failed',
      'image_saved',
      'video_frames_saved',
      'reused'
    ]) {
      for (final modelVideoHint in [false, true]) {
        await audit.finish(item.observation, state, {
          'modelVideoHint': modelVideoHint,
          'reason': 'late_crop_or_model_result',
          'parentMessageId': 'another-parent',
          'mediaReceiptId': 'another-receipt',
        });
        final after = await observation(item.observation);
        expect(after['state'], 'rejected_text',
            reason:
                'Late $state hint=$modelVideoHint cannot create media work');
        expect(jsonDecode(after['details']! as String), details);
        expect(await audit.captureResolved(item.observation), isTrue);
      }
    }
    expect(await db.isMessageFormallyAnswered('buyer', item.parent), isFalse,
        reason: 'Rejecting a false media observation is not a formal reply.');
    expect(await db.unansweredWorkCounts(), {'buyer': 1});
  });

  test(
      'text audit confirmation requires exact corrected parent and current run',
      () async {
    for (final kind in ['image', 'video']) {
      final media = await admit('actual-$kind');
      await inventory.classify(media.receipt, kind);
      await audit.confirmTextParent('buyer',
          parentMessageId: media.parent,
          receiptId: media.receipt,
          expectedSessionId: session);
      expect((await observation(media.observation))['state'], 'discovered',
          reason: 'An actual $kind has not been clarified as customer text.');
    }
    final text = await admit('clarified');
    final other = await admit('different-same-second-bubble');
    await clarify(text);
    for (final call in [
      (
        customer: 'another-customer',
        parent: text.parent,
        receipt: text.receipt,
        run: session
      ),
      (
        customer: 'buyer',
        parent: text.parent,
        receipt: text.receipt,
        run: 'previous-run'
      ),
      (
        customer: 'buyer',
        parent: text.parent,
        receipt: other.receipt,
        run: session
      ),
      (
        customer: 'buyer',
        parent: other.parent,
        receipt: text.receipt,
        run: session
      ),
    ]) {
      await audit.confirmTextParent(call.customer,
          parentMessageId: call.parent,
          receiptId: call.receipt,
          expectedSessionId: call.run);
      expect((await observation(text.observation))['state'], 'discovered');
      expect((await observation(other.observation))['state'], 'discovered');
    }

    // Persisted observations from a previous run must remain isolated even
    // when their local parent keys happen to resemble a corrected current one.
    final current = await observation(text.observation);
    final oldDetails = {
      ...jsonDecode(current['details']! as String) as Map<String, dynamic>,
      'automationSessionId': 'previous-run',
      'observationId': 'previous-run-observation',
    };
    await (await db.database).insert('media_capture_audit', {
      'observation_id': 'previous-run-observation',
      'evidence_id': 'previous-run-frame',
      'customer': 'buyer',
      'state': 'unverified',
      'details': jsonEncode(oldDetails),
      'updated_at_ms': received.millisecondsSinceEpoch,
    });
    await audit.confirmTextParent('buyer',
        parentMessageId: text.parent,
        receiptId: text.receipt,
        expectedSessionId: session);
    expect((await observation(text.observation))['state'], 'rejected_text');
    expect((await observation(other.observation))['state'], 'discovered');
    expect(
        (await observation('previous-run-observation'))['state'], 'unverified');
  });
}
