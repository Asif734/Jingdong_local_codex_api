import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';

void main() {
  test('read-only legacy history preserves filenames and contents', () async {
    final root = await Directory.systemTemp.createTemp('jd_read_history_');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/buyer.json');
    final bytes = jsonEncode({'user_id': 'buyer', 'messages': []});
    await file.writeAsString(bytes);
    final history = ConversationFileStore(root);
    expect((await history.readOnly('buyer'))?['user_id'], 'buyer');
    expect(await file.readAsString(), bytes);
    expect(await root.list().length, 1);
  });
  test('read-only daily history never initializes absent day files', () async {
    final root = await Directory.systemTemp.createTemp('jd_read_day_');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/buyer.json');
    final bytes = jsonEncode({'user_id': 'buyer', 'messages': []});
    await file.writeAsString(bytes);
    final history =
        ConversationFileStore.forDay(root, businessDay: '2026-11-23');
    expect(await history.readOnly('buyer'), isNull);
    expect(await file.readAsString(), bytes);
    expect(await root.list().length, 1);
  });
}
