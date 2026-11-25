import 'dart:convert';
import 'dart:io';

import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/message_record.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

/// Controlled state written by an older release, not a current admission API.
Future<MediaMessageAdmission> seedLegacyClocklessMediaOwner(
  CaptureDatabase db, {
  required String customer,
  required String receiptId,
  required String messageId,
  required String evidenceId,
  required String occurrenceKey,
  required DateTime receivedAt,
}) async {
  final store = await db.history;
  await store.appendCapture(CapturedConversation(
      stableKey: customer,
      customerName: customer,
      customerExternalId: customer,
      capturedAt: receivedAt,
      messages: [
        CapturedMessage(
            stableId: messageId,
            direction: 'incoming',
            body: '[Customer sent media; acquisition pending.]',
            sender: customer,
            axPath: 'controlled legacy owner',
            mediaReceiptId: receiptId,
            captureEvidenceId: evidenceId)
      ]));
  final document = (await store.read(customer))!;
  final message = (document['messages'] as List)
      .cast<Map<String, dynamic>>()
      .singleWhere((m) => m['id'] == messageId);
  message['live_observed_session_ids'] = [db.currentAutomationSessionId];
  message['observed_session_id'] = db.currentAutomationSessionId;
  message['capture_purpose'] = 'live_signal';
  await File(
          '${store.conversationsDirectory.path}/${store.safeUserId(customer)}.json')
      .writeAsString(jsonEncode(document));
  final sql = await db.database;
  await sql.update(
      'customer_media_items',
      {
        'message_id': messageId,
        'admission_key': occurrenceKey,
        'admission_session_id': db.currentAutomationSessionId,
        'admitted_at_ms': receivedAt.millisecondsSinceEpoch,
      },
      where: 'customer=? AND item_id=?',
      whereArgs: [customer, receiptId]);
  await sql.insert('automation_session_messages', {
    'session_id': db.currentAutomationSessionId,
    'user_id': customer,
    'message_id': messageId,
    'activated_at_ms': receivedAt.millisecondsSinceEpoch,
    'work_revision': 0,
    'input_kind': 'media',
    'input_key': ConversationFileStore.materialInputKey(message),
    'response_state': 'pending',
  });
  await db.ensurePendingForUnanswered(customer);
  return MediaMessageAdmission(
      messageId: messageId,
      receiptId: receiptId,
      admittedAt: receivedAt,
      created: false);
}
