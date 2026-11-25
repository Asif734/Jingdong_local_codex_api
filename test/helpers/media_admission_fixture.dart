import 'package:jd_automation/storage/capture_database.dart';

/// Unit fixtures must explicitly declare the live occurrence they are testing.
/// An observed receipt, copied file or ROI alone never registers business.
Future<void> admitFixtureMedia(CaptureDatabase db,
    {required String receiptId,
    required String messageId,
    required DateTime receivedAt,
    String customer = 'buyer',
    DateTime? senderAt}) async {
  final sql = await db.database;
  var root = receiptId;
  Map<String, Object?> row;
  final visited = <String>{};
  while (true) {
    if (!visited.add(root)) throw StateError('fixture_parent_cycle');
    row = (await sql.query('customer_media_items',
            where: 'customer=? AND item_id=?', whereArgs: [customer, root]))
        .single;
    if (row['canonical_id'] == null) break;
    root = row['canonical_id']! as String;
  }
  if (row['admission_session_id'] != null &&
      row['admission_session_id'] != db.currentAutomationSessionId) {
    return;
  }
  if (await db.isSessionBaselineMessage(customer, messageId)) return;
  await db.admitMediaMessage(customer,
      receiptId: root,
      evidenceId: 'fixture-$root',
      occurrenceKey: row['admission_key']?.toString() ?? 'fixture-live:$root',
      receivedAt: receivedAt,
      senderAt: senderAt,
      messageId: row['message_id']?.toString() ?? messageId);
}
