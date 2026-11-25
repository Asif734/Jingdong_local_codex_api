import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

import 'helpers/completed_video_fixture.dart';
import 'helpers/media_admission_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  late MediaCaptureAudit audit;
  late String session;
  late DateTime now;
  late OcrVisualRegion region;
  const customer = 'buyer';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v40_observation_');
    db = CaptureDatabase(storageRoot: root);
    now = DateTime.now().toUtc();
    session = await db.beginAutomationSession(startedAt: now);
    audit = MediaCaptureAudit(db);
    final fixture = jsonDecode(
        await File('test/fixtures/v35_media/unbound-video-frame.json')
            .readAsString()) as Map<String, dynamic>;
    final inspection = OcrInspection.fromMap(fixture);
    region = inspection.unboundMediaRegions.single;
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<ViewportEvidence> frame(String id) async {
    final image = await File('test/fixtures/v35_media/unbound-video-frame.png')
        .copy('${root.path}/$id.png');
    return ViewportEvidence({
      'evidenceId': id,
      'customer': customer,
      'automationSessionId': session,
      'capturedAtMs': now.millisecondsSinceEpoch,
      'imagePath': image.path,
      'manifestPath': '${root.path}/$id.json',
      'replyActivationAllowed': true,
      'capturePurpose': 'live_signal',
      'chatRegion': {
        'left': .24027777777777778,
        'top': .20418204182041821,
        'right': .7479166666666667,
        'bottom': .7921279212792128,
      },
    });
  }

  Future<(String, String)> readyParent({bool complete = true}) async {
    final inventory = CustomerMediaInventory(db);
    final receipt = await inventory.observe(
        customer: customer,
        evidenceId: 'original',
        observedAt: now,
        senderAt: now,
        occurrenceKey: 'original-arrival',
        slot: 0,
        region: [region.x, region.y, region.width, region.height],
        current: true);
    const parent = 'known-video';
    await admitFixtureMedia(db,
        receiptId: receipt, messageId: parent, receivedAt: now, senderAt: now);
    final media = await completedVideoFixture(root, name: 'known');
    final capture = CapturedConversation(
        stableKey: customer,
        customerName: customer,
        customerExternalId: customer,
        automationSessionId: session,
        capturedAt: now,
        messages: [
          CapturedMessage(
            stableId: parent,
            direction: 'incoming',
            body: '[Customer video]',
            sentAt: now,
            axPath: 'owned current customer',
            mediaReceiptId: receipt,
            media: complete ? media : [media[0], media[3]],
          )
        ]);
    await db.saveCapture(capture);
    await inventory.persist(capture, verifiedAnchor: true);
    return (receipt, parent);
  }

  for (final intermediate in [false, true]) {
    test(
        'resolved same-card parent closes later crop; unbound bridge=$intermediate',
        () async {
      final (receipt, parent) = await readyParent();
      final original = await frame('stored');
      final resolved = await audit.discoverUnbound(original, region);
      await audit.groupUnbound(original, region, resolved);
      await audit.bindParent(resolved, receiptId: receipt, messageId: parent);
      await audit.resolveStoredReceipt(customer, receipt);
      expect(await audit.captureResolved(resolved), isTrue);
      if (intermediate) {
        final bridge = await frame('bridge');
        final id = await audit.discoverUnbound(bridge, region);
        // Reproduce old durable unbound correspondence ahead of an older
        // terminal row; a newest-row match must not stop the parent search.
        final source = (await (await db.database).query('media_capture_audit',
                where: 'observation_id=?', whereArgs: [resolved]))
            .single;
        final details = jsonDecode(source['details']! as String) as Map;
        await (await db.database).update(
            'media_capture_audit',
            {
              'details': jsonEncode({
                'observationId': id,
                'evidenceId': bridge.id,
                'automationSessionId': session,
                'capturedAt': now.toIso8601String(),
                'sourceImagePath': bridge.imagePath,
                'previewPath': details['previewPath'],
                'region': details['region'],
                'observationGroupId': resolved,
              }),
              'updated_at_ms': DateTime.now().millisecondsSinceEpoch + 100,
            },
            where: 'observation_id=?',
            whereArgs: [id]);
      }
      final later = await frame('later-crop');
      final next = await audit.discoverUnbound(later, region);
      final group = await audit.groupUnbound(later, region, next);
      expect(group['resolvedMessageId'], parent);
      expect(group['parentMessageId'], parent);
      expect(group['state'], 'video_frames_saved');
      expect(await audit.captureResolved(next), isTrue);
      expect(await audit.pendingUnboundForCustomer(customer), isEmpty);
      expect(await db.unansweredWorkCounts(), {customer: 1},
          reason:
              'Resolving capture evidence neither adds nor answers business');
    });
  }

  test('retry of its own bound observation sees completed exact parent',
      () async {
    final (receipt, parent) = await readyParent();
    final evidence = await frame('own-bound');
    final id = await audit.discoverUnbound(evidence, region);
    await audit.bindParent(id, receiptId: receipt, messageId: parent);
    expect(await audit.captureResolved(id), isFalse);
    final result = await audit.groupUnbound(evidence, region, id);
    expect(result['resolvedMessageId'], parent);
    expect(result['state'], 'video_frames_saved');
    expect(await audit.captureResolved(id), isTrue);
    expect(await db.unansweredWorkCounts(), {customer: 1});
  });

  test('bound parent without decoded frames remains pending on retry',
      () async {
    final (receipt, parent) = await readyParent(complete: false);
    final evidence = await frame('own-pending');
    final id = await audit.discoverUnbound(evidence, region);
    await audit.bindParent(id, receiptId: receipt, messageId: parent);
    final result = await audit.groupUnbound(evidence, region, id);
    expect(result['resolvedMessageId'], isNull);
    expect(result['parentMessageId'], parent);
    expect(result['state'], 'unbound');
    expect(await audit.captureResolved(id), isFalse);
    expect(await db.isMessageFormallyAnswered(customer, parent), isFalse);
    expect(await db.unansweredWorkCounts(), {customer: 1});
  });
}
