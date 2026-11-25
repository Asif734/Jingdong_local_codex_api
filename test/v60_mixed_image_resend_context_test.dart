import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';

// The storage suite proves creation/ownership of this projection. This suite
// verifies the service consumes its contract and still invokes the model for a
// mixed invoice + technical question instead of returning a fixed notice.
class _ResendProjectionDatabase extends CaptureDatabase {
  _ResendProjectionDatabase({required super.storageRoot});
  static const expiredImage = 'incoming-time:buyer:2026-11-12T00:00:00Z';

  @override
  Future<List<Map<String, dynamic>>> generationMessages(String customer,
      {String? batchEndMessageId, Map<String, dynamic>? document}) async {
    final messages = await super.generationMessages(customer,
        batchEndMessageId: batchEndMessageId, document: document);
    return messages
        .map((message) => {
              ...message,
              if (message['direction'] == 'incoming')
                'incomplete_image_resend_required': {
                  'expired_image_message_ids': [expiredImage],
                  'source_receipt_id': 'expired-source',
                  'reason': 'incomplete_image_expired',
                }
            })
        .toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'mixed expired-image reference reaches CLI with resend context and its real answer',
      () async {
    final root =
        await Directory.systemTemp.createTemp('jd_v60_resend_context_');
    final db =
        _ResendProjectionDatabase(storageRoot: Directory('${root.path}/data'));
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await Directory('${root.path}/workspace').create();
    await Directory('${root.path}/knowledge').create();
    await File('${root.path}/knowledge/controlled_kb.md').writeAsString(
        'Controlled fixture: connect the USB cable between printer and computer and install its matching driver.');
    final at = DateTime.now().toUtc();
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        customerExternalId: 'buyer',
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: 'mixed',
              direction: 'incoming',
              sender: 'buyer',
              body: '我要开票，抬头在之前那张图片里，另外USB怎么连接电脑？',
              sentAt: at,
              axPath: 'controlled mixed question')
        ]));
    const answer = '先用USB线连接打印机和电脑，再安装对应型号驱动。之前的图片可能因网络原因未能完整加载，麻烦您重新发送一下。';
    final response = File('${root.path}/response.json');
    await response.writeAsString(jsonEncode({
      'reply': answer,
      'reply_purpose': 'substantive',
      'decision': 'draft',
      'confidence': 1,
      'risk_level': 'low',
      'human_review_required': false,
      'auto_send_allowed': false,
      'risk_triggers': [],
      'actions': [],
      'attachments': [],
      'used_record_ids': ['controlled'],
      'image_descriptions': []
    }));
    final prompt = File('${root.path}/request.txt');
    final cli = File('${root.path}/controlled-cli.py');
    await cli.writeAsString('''#!/usr/bin/python3
import sys,pathlib
args=sys.argv[1:]
pathlib.Path(${jsonEncode(prompt.path)}).write_text(sys.stdin.read())
pathlib.Path(args[args.index('--output-last-message')+1]).write_text(pathlib.Path(${jsonEncode(response.path)}).read_text())
''');
    expect((await Process.run('chmod', ['+x', cli.path])).exitCode, 0);
    final service = CodexReplyService(
        executable: cli.path,
        workspace: Directory('${root.path}/workspace'),
        knowledgeDirectory: Directory('${root.path}/knowledge'),
        outputSchema: File('${root.path}/schema.json'),
        timeout: const Duration(seconds: 10),
        capacityRetryDelays: const []);
    final draft = await service.generate(
        conversation: (await db.conversations()).single, database: db);
    expect(draft.reply.replaceAll(RegExp(r'\s+'), ''),
        contains(answer.replaceAll(RegExp(r'\s+'), '')));
    expect(isExplicitHumanTransfer(draft), isFalse);
    final requestText = await prompt.readAsString();
    final request = jsonDecode(requestText
        .split('<request_json>')
        .last
        .split('</request_json>')
        .first) as Map;
    final refs = request['incomplete_image_resend_required'] as List;
    expect((refs.single as Map)['expired_image_message_ids'],
        [_ResendProjectionDatabase.expiredImage]);
    expect(requestText, contains('Ask the customer to resend that image'));
    expect(requestText, contains('Answer every independent text question'));
    expect(request['invoice_collection'], isNotNull);
  });
}
