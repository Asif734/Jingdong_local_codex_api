import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/customer_message_time.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const customer = 'audit-buyer';
  final at = DateTime.utc(2026, 11, 12, 2);
  late Directory root;
  late CaptureDatabase db;
  late MediaCaptureAudit audit;
  late String session;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v60_expired_audit_');
    db = CaptureDatabase(
        storageRoot: root, currentDayOnly: true, clock: () => at);
    session = await db.beginAutomationSession(startedAt: at);
    audit = MediaCaptureAudit(db);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> observed(int second,
      {String responseState = 'pending', bool video = false}) async {
    final stamp = at.add(Duration(seconds: second));
    final id = CustomerMessageTime.incomingId(customer, stamp);
    final sql = await db.database;
    await sql.insert('automation_session_messages', {
      'session_id': session,
      'user_id': customer,
      'message_id': id,
      'activated_at_ms': stamp.millisecondsSinceEpoch,
      'response_state': responseState,
      'input_kind': 'media',
    });
    final proof = {
      'version': 1,
      'sessionId': session,
      'customer': customer,
      'observationGroupId': id,
      'occurrenceKey': id,
      'arrivalKey': 'arrival:$second',
      'region': [.3, .4, .1, .2],
      'capturedAt': stamp.toIso8601String(),
      'evidenceId': 'frame-$second',
    };
    await sql.insert('media_capture_audit', {
      'observation_id': 'observation-$second',
      'evidence_id': 'frame-$second',
      'customer': customer,
      'state': video ? 'video_preview_only' : 'image_partial',
      'details': jsonEncode({
        'automationSessionId': session,
        'parentMessageId': id,
        'observationGroupId': id,
        'senderClock': stamp.toIso8601String(),
        'capturedAt': stamp.toIso8601String(),
        'liveArrivalProof': proof,
      }),
      'updated_at_ms': stamp.millisecondsSinceEpoch,
    });
    return id;
  }

  for (final state in ['skipped_image', 'resend_requested']) {
    test('$state ends old image recovery while a new video stays actionable',
        () async {
      await observed(1, responseState: state);
      await observed(2, video: true);
      final recovery = await audit.pendingAdmissionRecoveries();
      expect(recovery.map((row) => row['observationId']), ['observation-2']);
      final gaps = await audit.pendingAdmissionGaps();
      // The video already has an admitted message; recovery can continue
      // without counting it as a missing registration.
      expect(gaps, isEmpty);
      final context = await audit.pendingForCustomer(customer,
          before: at.add(const Duration(minutes: 5)));
      expect(context.map((row) => row['observationId']), ['observation-2']);
    });
  }

  test('an unsent resend notice also ends recovery of the expired image',
      () async {
    final id = await observed(1);
    await observed(2);
    await (await db.database).insert('automation_message_waits', {
      'session_id': session,
      'user_id': customer,
      'message_id': id,
      'is_media': 1,
      'content_key': 'image-expiry:${jsonEncode({
            'version': 1,
            'session_id': session,
            'source_message_id': id,
            'status': 'resend_due',
          })}',
      'message_revision': 0,
      'task_id': 'image-expiry:$id',
      'updated_at_ms':
          at.add(const Duration(minutes: 3)).millisecondsSinceEpoch,
    });
    expect(
        (await audit.pendingAdmissionRecoveries())
            .map((row) => row['observationId']),
        ['observation-2']);
    expect(
        (await audit.pendingForCustomer(customer,
                before: at.add(const Duration(minutes: 5))))
            .map((row) => row['observationId']),
        ['observation-2']);
  });
}
