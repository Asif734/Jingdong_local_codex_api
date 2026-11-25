import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _customer = 'portable-schema-buyer';
const _oldMessageColumns = [
  'session_id',
  'user_id',
  'message_id',
  'activated_at_ms',
  'response_state',
  'answered_task_id',
  'answered_attempt_id',
  'responded_at_ms',
  'work_revision',
  'evidence_key',
  'input_kind',
];

AiDraft _answer(String text) => AiDraft.fromJson({
      'reply': text,
      'reply_purpose': 'substantive',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'model': 'controlled-schema-fixture',
      'auto_send_allowed': false,
      'reply_media_dependency_keys': <String, String>{},
      'image_descriptions': <Object>[],
    }, mediaBaseUrl: Uri());

Future<void> _receive(CaptureDatabase db, String id) => db
    .saveCapture(CapturedConversation(
        stableKey: _customer,
        customerName: _customer,
        customerExternalId: _customer,
        automationSessionId: db.currentAutomationSessionId,
        capturedAt: DateTime.now().toUtc(),
        messages: [
          CapturedMessage(
              stableId: id,
              direction: 'incoming',
              sender: _customer,
              body: 'A real customer question $id',
              sentAt: DateTime.now().toUtc(),
              axPath: 'controlled exact AX customer')
        ]))
    .then((_) {});

Future<void> _generate(CaptureDatabase db, String id, String reply) async {
  final conversation = (await db.conversation(_customer))!;
  final token = (await db.beginGeneration(
      customer: _customer, pendingId: conversation.id, batchEndMessageId: id))!;
  final inputs = (await db.generationMessages(_customer))
      .where((message) => message['direction'] == 'incoming');
  expect(inputs.map((message) => message['id']), [id]);
  final draft = await db.prepareAutomaticDraft(_customer, _answer(reply));
  expect(
      await db.saveDraft(conversation.id, draft,
          expectedMessageId: id,
          expectedUserId: _customer,
          generationToken: token),
      1);
  await db.abandonGeneration(_customer, token);
}

Future<void> _submit(CaptureDatabase db, String reply) async {
  final attempt =
      await db.beginDeliveryAttempt(userId: _customer, reply: reply);
  final clicked = DateTime.now().millisecondsSinceEpoch;
  await File(attempt['receiptPath']!).writeAsString(jsonEncode({
    'attemptId': attempt['attemptId'],
    'customer': _customer,
    'state': 'submitted',
    'sendClickedAtMs': clicked,
    'timeMs': clicked,
  }));
  await db.recoverDeliveryReceipts();
}

Future<Map<String, Object?>> _businessSnapshot(Database db) async => {
      for (final table in const [
        'automation_sessions',
        'automation_session_messages',
        'automation_reply_inputs',
        'automation_message_waits',
        'automation_message_evidence',
        'pending_customers',
        'generated_drafts',
        'delivery_attempts',
        'answered_cursors',
        'sla_fallbacks',
        'sla_delivery_receipts',
        'conversation_control',
      ])
        table: [
          for (final row
              in await db.rawQuery('SELECT * FROM $table ORDER BY rowid'))
            {
              for (final entry in row.entries)
                if (!(table == 'automation_session_messages' &&
                    entry.key == 'input_key'))
                  entry.key: entry.value
            },
        ],
    };

Future<Map<String, String>> _receiptFiles(Directory root) async {
  final directory = Directory('${root.path}/delivery_receipts');
  if (!await directory.exists()) return {};
  return {
    for (final file
        in await directory.list().where((entry) => entry is File).toList())
      file.path.split('/').last: await (file as File).readAsString()
  };
}

/// No production/customer database is used. The unchanged public tables are
/// created locally, then the message table is rebuilt with the exact v34 DDL
/// (11 original columns, without input_key) and an old declared schema version.
Future<CaptureDatabase> _portableOldDatabase(Directory root,
    {int declaredVersion = 34}) async {
  final db = CaptureDatabase(storageRoot: root);
  await db.beginAutomationSession(
      startedAt: DateTime.now().toUtc().subtract(const Duration(seconds: 1)));
  await _receive(db, 'old-answered');
  await _generate(db, 'old-answered', 'Previously submitted answer.');
  await _submit(db, 'Previously submitted answer.');
  await _receive(db, 'old-ready');
  await _generate(db, 'old-ready', 'Ready answer kept through upgrade.');
  await _receive(db, 'old-queued');
  final sql = await db.database;
  await sql.transaction((txn) async {
    await txn.execute(
        'ALTER TABLE automation_session_messages RENAME TO fixture_v35_messages');
    await txn.execute('''CREATE TABLE automation_session_messages(
      session_id TEXT NOT NULL,user_id TEXT NOT NULL,message_id TEXT NOT NULL,
      activated_at_ms INTEGER NOT NULL,response_state TEXT NOT NULL DEFAULT 'pending',
      answered_task_id TEXT,answered_attempt_id TEXT,responded_at_ms INTEGER,
      work_revision INTEGER NOT NULL DEFAULT 0,evidence_key TEXT,
      input_kind TEXT NOT NULL DEFAULT 'unknown',
      PRIMARY KEY(session_id,user_id,message_id))''');
    final columns = _oldMessageColumns.join(',');
    await txn.execute('INSERT INTO automation_session_messages($columns) '
        'SELECT $columns FROM fixture_v35_messages');
    await txn.execute('DROP TABLE fixture_v35_messages');
    await txn.execute('PRAGMA user_version=$declaredVersion');
  });
  final columns =
      await sql.rawQuery('PRAGMA table_info(automation_session_messages)');
  expect(columns.map((column) => column['name']), isNot(contains('input_key')));
  expect((await sql.rawQuery('PRAGMA user_version')).single['user_version'],
      declaredVersion);
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v41_schema_');
    db = CaptureDatabase(storageRoot: root);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test('a new database has schema35 and nullable input_key before Start',
      () async {
    await db.ensureAutomationSchemaReady();
    final sql = await db.database;
    expect(
        (await sql.rawQuery('PRAGMA user_version')).single['user_version'], 35);
    final columns =
        await sql.rawQuery('PRAGMA table_info(automation_session_messages)');
    final input =
        columns.singleWhere((column) => column['name'] == 'input_key');
    expect(input['type'], 'TEXT');
    expect(input['notnull'], 0);
    expect(await sql.query('automation_sessions'), isEmpty);
    await db.ensureAutomationSchemaReady();
    expect(await sql.query('automation_sessions'), isEmpty);
  });

  test(
      'a real v34 message table upgrades without changing customer work or receipts',
      () async {
    await db.close();
    db = await _portableOldDatabase(root);
    final before = await _businessSnapshot(await db.database);
    final history = File('${root.path}/$_customer.json');
    final historyBefore = await history.readAsString();
    final receipts = await _receiptFiles(root);
    expect(receipts, isNotEmpty);
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    await db.ensureAutomationSchemaReady();
    final sql = await db.database;
    expect(
        (await sql.rawQuery('PRAGMA user_version')).single['user_version'], 35);
    expect(await _businessSnapshot(sql), before);
    expect(await history.readAsString(), historyBefore);
    expect(await _receiptFiles(root), receipts);
    final restored = await sql.query('automation_session_messages');
    expect(restored, hasLength(3));
    expect(restored.every((row) => row['input_key'] == null), isTrue,
        reason:
            'Adding the nullable column must not invent evidence for old rows');

    // A new Start archives the old business as usual; it must then be able to
    // register fresh work, freeze its real input and commit a native receipt.
    final session =
        await db.beginAutomationSession(startedAt: DateTime.now().toUtc());
    await _receive(db, 'new-live-question');
    final admitted = (await sql.query('automation_session_messages',
            where: 'session_id=?', whereArgs: [session]))
        .single;
    expect(admitted['message_id'], 'new-live-question');
    expect(admitted['input_key'],
        isA<String>().having((key) => key.length, 'hash length', 64));
    expect(await db.generationDue(_customer), isTrue);
    await _generate(db, 'new-live-question',
        'Fresh answer after upgrading the old database.');
    await _submit(db, 'Fresh answer after upgrading the old database.');
    expect(await db.isMessageFormallyAnswered(_customer, 'new-live-question'),
        isTrue);
    expect(await db.hasPendingUnanswered(_customer), isFalse);
    expect(await db.hasUndeliveredDraft(_customer), isFalse);
    final archive = await sql.query('automation_work_archive',
        where: 'session_id=? AND table_name=?',
        whereArgs: [session, 'generated_drafts']);
    expect(archive.single['row_json'],
        contains('Ready answer kept through upgrade.'));
  });

  test(
      'same-version35 missing only input_key repairs idempotently without resetting rows',
      () async {
    await db.close();
    db = await _portableOldDatabase(root, declaredVersion: 35);
    final before = await _businessSnapshot(await db.database);
    final history = File('${root.path}/$_customer.json');
    final historyBefore = await history.readAsString();
    final receipts = await _receiptFiles(root);
    for (var pass = 0; pass < 2; pass++) {
      await db.close();
      db = CaptureDatabase(storageRoot: root);
      await db.ensureAutomationSchemaReady();
      final sql = await db.database;
      expect(
          (await sql.rawQuery('PRAGMA table_info(automation_session_messages)'))
              .where((row) => row['name'] == 'input_key'),
          hasLength(1));
      expect(await _businessSnapshot(sql), before);
      expect(await history.readAsString(), historyBefore);
      expect(await _receiptFiles(root), receipts);
    }
  });

  test(
      'the explicit pre-Start check also repairs an already-open safe missing column',
      () async {
    await db.close();
    db = await _portableOldDatabase(root, declaredVersion: 35);
    final before = await _businessSnapshot(await db.database);
    final currentSession = db.currentAutomationSessionId;
    await db.ensureAutomationSchemaReady();
    expect(db.currentAutomationSessionId, currentSession);
    expect(await _businessSnapshot(await db.database), before);
    expect(
        (await (await db.database)
                .rawQuery('PRAGMA table_info(automation_session_messages)'))
            .map((row) => row['name']),
        contains('input_key'));
  });

  test(
      'unknown missing structure fails before recovery and rolls back the safe column repair',
      () async {
    await db.close();
    db = await _portableOldDatabase(root, declaredVersion: 35);
    final sql = await db.database;
    await sql.execute(
        'ALTER TABLE automation_reply_inputs DROP COLUMN message_json');
    await sql.update('generated_drafts', {'delivery_state': 'sending'});
    await sql.update(
        'pending_customers', {'generation_token': 'must-remain-untouched'});
    final before = await _businessSnapshot(sql);
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    await expectLater(
        db.ensureAutomationSchemaReady(),
        throwsA(isA<StateError>().having(
            (error) => error.message,
            'startup schema error',
            allOf(
                contains('database_schema_incompatible'),
                contains('automation_reply_inputs'),
                contains('message_json')))));
    final raw = await databaseFactoryFfi
        .openDatabase('${root.path}/jd_automation.sqlite3');
    try {
      expect(await _businessSnapshot(raw), before);
      expect(
          (await raw.rawQuery('PRAGMA table_info(automation_session_messages)'))
              .map((row) => row['name']),
          isNot(contains('input_key')));
      expect((await raw.query('generated_drafts')).single['delivery_state'],
          'sending');
      expect((await raw.query('pending_customers')).single['generation_token'],
          'must-remain-untouched');
    } finally {
      await raw.close();
    }
  });

  test(
      'cleanup retains exact uncertain ledger ownership without confirming delivery',
      () async {
    final session = await db.beginAutomationSession(
        startedAt: DateTime.now().toUtc().subtract(const Duration(seconds: 1)));
    await _receive(db, 'uncertain-question');
    const reply = 'An answer whose native submission is still uncertain.';
    await _generate(db, 'uncertain-question', reply);
    final attempt =
        await db.beginDeliveryAttempt(userId: _customer, reply: reply);
    final sql = await db.database;
    final row = (await sql.query('delivery_attempts',
            where: 'attempt_id=?', whereArgs: [attempt['attemptId']]))
        .single;
    final store = await db.history;
    await store.appendSentReply(
        userId: _customer,
        displayName: _customer,
        stableKey: _customer,
        draft: _answer(reply),
        taskId: row['task_id']! as String,
        attemptId: row['attempt_id']! as String,
        batchEndMessageId: 'uncertain-question');
    final document = (await store.read(_customer))!;
    final messages =
        (document['messages'] as List).cast<Map<String, dynamic>>();
    final owned = Map<String, dynamic>.from(messages.last);
    expect(owned['delivery_status'], 'submitted');
    for (final mismatch in <String, String>{
      'delivery_task_id': 'another-task',
      'answered_batch_end_id': 'another-batch',
      'body': 'Different generated text',
      'delivery_attempt_id': 'no-such-ledger-attempt',
    }.entries) {
      messages.add({
        ...owned,
        'id': 'forged-${mismatch.key}',
        mismatch.key: mismatch.value
      });
    }
    document['messages'] = messages;
    await File('${root.path}/$_customer.json')
        .writeAsString(jsonEncode(document));
    const foreign = 'different-customer';
    await File('${root.path}/$foreign.json').writeAsString(jsonEncode({
      ...document,
      'user_id': foreign,
      'display_name': foreign,
      'stable_key': foreign,
      'messages': [owned],
    }));
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    await db.ensureAutomationSchemaReady();
    final reopened = await db.database;
    final retained =
        (jsonDecode(await File('${root.path}/$_customer.json').readAsString())[
                'messages'] as List)
            .cast<Map>()
            .where((message) => message['direction'] == 'outgoing')
            .toList();
    expect(retained, [owned],
        reason:
            'A submitted string alone or another ownership scope is not proof');
    expect(
        jsonDecode(await File('${root.path}/$foreign.json').readAsString())[
            'messages'],
        isEmpty);
    expect(
        (await reopened.query('delivery_attempts',
                where: 'attempt_id=?', whereArgs: [attempt['attemptId']]))
            .single['state'],
        'recovered_waiting');
    expect((await reopened.query('generated_drafts')).single['delivery_state'],
        'delivery_unknown');
    expect(
        (await reopened.query('automation_session_messages',
                where: 'session_id=? AND message_id=?',
                whereArgs: [session, 'uncertain-question']))
            .single['response_state'],
        'pending');
    expect(await reopened.query('answered_cursors'), isEmpty);
    expect(await File(attempt['receiptPath']!).exists(), isFalse,
        reason: 'Keeping audit history cannot manufacture native confirmation');
  });

  test(
      'an invalid message identity key fails explicitly without guessing a rebuild',
      () async {
    final sql = await db.database;
    await sql.execute(
        'ALTER TABLE automation_session_messages RENAME TO original_message_table');
    await sql.execute(
        'CREATE TABLE automation_session_messages AS SELECT * FROM original_message_table');
    await sql.execute('DROP TABLE original_message_table');
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    await expectLater(
        db.ensureAutomationSchemaReady(),
        throwsA(isA<StateError>().having((error) => error.message,
            'identity error', contains('identity key is invalid'))));
  });
}
