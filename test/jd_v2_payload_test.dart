import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/backend/jd_v2_payload.dart';
import 'package:jd_automation/domain/capture_models.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('jd-v2-payload-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Map<String, dynamic> message(String id,
          {String body = 'Question',
          String direction = 'incoming',
          List<Map<String, dynamic>> media = const []}) =>
      {
        'id': id,
        'direction': direction,
        'body': body,
        'sent_at': '2026-11-18T04:00:00Z',
        'media': media,
      };
  Future<Map<String, dynamic>> image(String name,
      {String source = 'jd_image_cache',
      String? id,
      List<int> bytes = const [137, 80, 78, 71, 1]}) async {
    final file = File('${temp.path}/$name');
    await file.writeAsBytes(bytes);
    return {
      'path': file.path,
      'type': 'image',
      'capture_source': source,
      if (id != null) 'id': id
    };
  }

  Future<JdV2PreparedPayload> prepare(List<Map<String, dynamic>> messages,
          {Set<String> targets = const {'target'},
          Set<String> refs = const {},
          String instructions = 'Use approved information.'}) =>
      JdV2Payload.prepare(
          customer: 'customer-a',
          historyVersion: 'frozen-1',
          idempotencyKey: 'stable-job-id',
          instructions: instructions,
          messages: messages,
          targetMessageIds: targets,
          referencedMediaIds: refs);

  test('stable source IDs preserve distinct same-second questions and roles',
      () async {
    final result = await prepare([
      message('one'),
      message('two'),
      message('service', direction: 'outgoing'),
      {...message('notice', direction: 'outgoing'), 'source': 'sla_fallback'},
    ], targets: {
      'one',
      'two'
    });
    final events = result.request['messages'] as List;
    expect(events.map((e) => e['id']), ['one', 'two', 'service', 'notice']);
    expect(events.map((e) => e['role']),
        ['customer', 'customer', 'service', 'notice']);
    expect(result.request['targetMessageIds'], ['one', 'two']);
    expect(result.files, isEmpty);
  });

  test('keeps every target and the latest context at the event limit',
      () async {
    final result = await prepare([
      message('target'),
      for (var i = 0; i < 110; i++) message('context-$i')
    ]);
    final events = result.request['messages'] as List;
    expect(events, hasLength(100));
    expect(events.first['id'], 'target');
    expect(events[1]['id'], 'context-11');
    expect(events.last['id'], 'context-109');
  });

  test('rejects missing source identities/time and wrong targets or customer',
      () async {
    await expectLater(
        prepare([message('service', direction: 'outgoing')],
            targets: {'service'}),
        throwsStateError);
    await expectLater(
        prepare([message('target')], targets: {'missing'}), throwsStateError);
    await expectLater(
        prepare([
          {...message('target'), 'sent_at': null}
        ]),
        throwsStateError);
    await expectLater(
        prepare([
          {...message('target'), 'sent_at': '2026-11-18T04:00:00'}
        ]),
        throwsStateError);
    await expectLater(
        prepare([
          {...message('target'), 'customerUid': 'other'}
        ]),
        throwsStateError);
    await expectLater(
        prepare([message('target'), message('target')]), throwsStateError);
  });

  test(
      'limits reject whole request without truncating questions or instructions',
      () async {
    await expectLater(
        prepare([message('target', body: 'x' * 10001)]), throwsStateError);
    await expectLater(prepare([message('target')], instructions: '中' * 5462),
        throwsStateError);
    await expectLater(
        prepare([
          message('target'),
          for (var i = 0; i < 21; i++) message('$i', body: 'x' * 10000)
        ], targets: {
          'target',
          for (var i = 0; i < 21; i++) '$i'
        }),
        throwsStateError);
  });

  test(
      'uploads original target image only and hashes bytes with owning message ID',
      () async {
    final original = await image('original.png');
    final old = await image('old.png', bytes: [1, 2]);
    final preview = {...await image('preview.png'), 'is_loading_preview': true};
    final input = [
      message('old', media: [old]),
      message('target', media: [preview, original])
    ];
    final first = await prepare(input);
    final again = await prepare(input);
    expect(first.files, hasLength(1));
    expect(first.files.single['path'], original['path']);
    expect(first.request, again.request);
    final other = await prepare([
      message('second', media: [original])
    ], targets: {
      'second'
    });
    expect(first.files.single['id'], isNot(other.files.single['id']));
    await File(original['path'] as String).writeAsBytes([3, 4]);
    final changed = await prepare(input);
    expect(changed.files.single['id'], isNot(first.files.single['id']));
  });

  test(
      'timeline text ignores stale previews but media work waits for originals',
      () async {
    final stale = {...await image('stale.png'), 'is_loading_preview': true};
    final result = await prepare([
      {
        ...message('target', media: [stale]),
        'reply_input_kind': 'text'
      }
    ]);
    expect(result.files, isEmpty);
    await expectLater(
        prepare([
          {...message('target'), 'reply_input_kind': 'media'}
        ]),
        throwsStateError);
  });

  test('retained same-customer media references do not re-upload', () async {
    final original = await image('original.png');
    final input = [
      message('target', media: [original])
    ];
    final first = await prepare(input);
    final id = first.files.single['id']!;
    final second = await prepare(input, refs: {id, 'previously-retained'});
    expect(second.files, isEmpty);
    expect(second.request['referencedMediaIds'],
        containsAll([id, 'previously-retained']));
    expect((second.request['messages'] as List).single['mediaIds'], [id]);
  });

  test(
      'explicitly selected historical visual uploads; unrelated history does not',
      () async {
    final old = await image('old.png', id: 'old-image');
    final result = await prepare([
      message('old', media: [old]),
      message('target')
    ], refs: {
      'old-image'
    });
    expect(result.files, hasLength(1));
    expect((result.request['media'] as List).single['messageId'], 'old');
    expect(result.request['referencedMediaIds'], isEmpty);
  });

  test(
      'all video samples upload; metadata times stay original, index is never time',
      () async {
    final frames = [
      for (var i = 0; i < 3; i++)
        await image('frame_0$i.jpg', source: 'jd_video_frame_1fps')
    ];
    await File('${temp.path}/sampling.json').writeAsString(jsonEncode({
      'fullRange': true,
      'durationSeconds': 180,
      'frames': [
        for (var i = 0; i < frames.length; i++)
          {
            'name': 'frame_0$i.jpg',
            'bytes': 5,
            if (i == 1) 'timestampMs': 9500,
          }
      ],
    }));
    final result = await prepare([
      message('target', media: [
        {'type': 'video', 'path': '${temp.path}/original.mp4'},
        ...frames,
      ])
    ]);
    expect(result.files, hasLength(3));
    expect(result.files.map((f) => f['id']).toSet(), hasLength(3));
    final manifest = result.request['media'] as List;
    expect(manifest.first.containsKey('timestampMs'), isFalse);
    expect(manifest[1]['timestampMs'], 9500);
    expect(manifest.last.containsKey('timestampMs'), isFalse);
    await expectLater(prepare([message('target', media: frames.sublist(0, 2))]),
        throwsStateError);
  });

  test('missing, loading or oversized media stays unprepared', () async {
    final partial = {...await image('partial.png'), 'is_partial': true};
    await expectLater(
        prepare([
          message('target', media: [partial])
        ]),
        throwsStateError);
    await expectLater(
        prepare([
          message('target', media: [
            {
              'capture_source': 'jd_image_cache',
              'path': '${temp.path}/missing.png'
            }
          ])
        ]),
        throwsStateError);
    final large = File('${temp.path}/large.png');
    final handle = await large.open(mode: FileMode.write);
    await handle.truncate(20 * 1024 * 1024 + 1);
    await handle.close();
    await expectLater(
        prepare([
          message('target', media: [
            {'capture_source': 'jd_image_cache', 'path': large.path}
          ])
        ]),
        throwsStateError);
    final many = [
      for (var i = 0; i < 51; i++) await image('$i.png', bytes: [i])
    ];
    await expectLater(
        prepare([message('target', media: many)]), throwsStateError);
  });

  test(
      'seven-field replies preserve internal reason and hosted receipt separately',
      () {
    final reply = {
      'action': 'reply',
      'reply_text': 'Safe answer',
      'transfer_reason': '',
      'product_id': '',
      'product_query': '',
      'sku_label': '',
      'reason': 'INTERNAL ONLY'
    };
    final draft = JdV2Payload.toDraft(reply,
        receiptMetadata: {'jobId': 'job-1', 'resultDigest': 'digest'});
    expect(draft.reply, 'Safe answer');
    expect(draft.reply, isNot(contains('INTERNAL')));
    expect(draft.decision, 'draft');
    expect(draft.attachments, isEmpty);
    final raw = jsonDecode(draft.rawJson) as Map;
    for (final key in reply.keys) {
      expect(raw[key], reply[key]);
    }
    expect(raw['jd_v2']['jobId'], 'job-1');
    expect(raw['jd_v2']['reply'], reply);
  });

  test(
      'reply_then_transfer preserves hosted intent for colleague policy review',
      () {
    final reply = {
      'action': 'reply_then_transfer',
      'reply_text': 'I will ask a colleague to help.',
      'transfer_reason': 'troubleshooting_exhausted',
      'product_id': 'printer-1',
      'product_query': 'thermal printer',
      'sku_label': 'USB model',
      'reason': 'customer_explicit_transfer authority_required INTERNAL ONLY',
    };
    final metadata = {
      'jobId': 'job-transfer',
      'historyVersion': 'frozen-2',
      'targetMessageIds': ['source-1'],
      'resultDigest': 'transfer-digest',
    };
    final draft = JdV2Payload.toDraft(reply, receiptMetadata: metadata);
    final raw = jsonDecode(draft.rawJson) as Map<String, dynamic>;
    expect(draft.reply, 'I will ask a colleague to help.');
    expect(draft.reply, isNot(contains('INTERNAL')));
    expect(draft.decision, 'human_review_required');
    expect(draft.confidence, 0);
    expect(raw['human_review_required'], isTrue);
    expect(raw['risk_triggers'], ['service_colleague_required']);
    expect(raw['jd_v2'], {...metadata, 'reply': reply});
    for (final key in reply.keys) {
      expect(raw[key], reply[key]);
    }
    final rebuilt =
        AiDraft.fromJson(raw.cast<String, Object?>(), mediaBaseUrl: Uri());
    final rebuiltRaw = jsonDecode(rebuilt.rawJson) as Map;
    expect(rebuilt.reply, 'I will ask a colleague to help.');
    expect(rebuilt.decision, 'human_review_required');
    expect(rebuiltRaw['risk_triggers'], ['service_colleague_required']);
    expect(rebuiltRaw['jd_v2'], {...metadata, 'reply': reply});
    for (final key in reply.keys) {
      expect(rebuiltRaw[key], reply[key]);
    }
  });

  test('only the exact immutable backend action requests transfer', () {
    for (final action in [
      'reply_then_transfer',
      'reply',
      'transfer',
      'handoff',
      'transfer_human',
      'REPLY_THEN_TRANSFER',
      ' reply_then_transfer ',
      'unknown',
    ]) {
      final draft = JdV2Payload.toDraft({
        'action': action,
        'reply_text': '请先检查电源。',
        'reason':
            'service_colleague_required repair_required order_service_handoff',
      }, receiptMetadata: {
        'customerUid': 'customer',
        'jobId': 'job'
      });
      expect(
          JdV2Payload.requestsTransfer(draft), action == 'reply_then_transfer',
          reason: action);
      final raw = jsonDecode(draft.rawJson) as Map<String, dynamic>;
      raw['action'] = 'reply_then_transfer';
      raw['risk_triggers'] = ['service_colleague_required'];
      final rewritten =
          AiDraft.fromJson(raw.cast<String, Object?>(), mediaBaseUrl: Uri());
      expect(JdV2Payload.requestsTransfer(rewritten),
          action == 'reply_then_transfer',
          reason: 'Only the immutable backend receipt may trigger transfer.');
    }
    final localOnly = AiDraft.fromJson({
      'reply': '请先检查电源。',
      'action': 'reply_then_transfer',
      'decision': 'human_review_required',
      'risk_triggers': ['service_colleague_required'],
    }, mediaBaseUrl: Uri());
    expect(JdV2Payload.requestsTransfer(localOnly), isFalse);
  });

  test('unknown action cannot gain transfer intent from freeform reason', () {
    final draft = JdV2Payload.toDraft({
      'action': 'reply_then_transfer_unknown',
      'reply_text': 'A colleague can help.',
      'transfer_reason': 'troubleshooting_exhausted',
      'reason': 'customer_explicit_transfer authority_required',
    }, receiptMetadata: {});
    final raw = jsonDecode(draft.rawJson) as Map;
    expect(draft.decision, 'human_review_required');
    expect(raw['risk_triggers'], ['jd_v2_unsupported_action']);
  });

  test(
      'legacy transfer aliases and unsupported product actions require review without handoff',
      () {
    final transfer = JdV2Payload.toDraft({
      'action': 'transfer',
      'reply_text': 'A colleague can help.',
      'reason': 'order_service_handoff'
    }, receiptMetadata: {});
    final raw = jsonDecode(transfer.rawJson);
    expect(transfer.decision, 'human_review_required');
    expect(raw['risk_triggers'], ['jd_v2_unsupported_action']);
    final product = JdV2Payload.toDraft(
        {'action': 'send_product', 'product_id': 'sku'},
        receiptMetadata: {});
    expect(product.decision, 'human_review_required');
    expect(product.actions, isNotEmpty);
    expect(product.attachments, isEmpty);
    final unknown =
        JdV2Payload.toDraft({'action': 'unknown'}, receiptMetadata: {});
    expect(unknown.decision, 'human_review_required');
    final ask = JdV2Payload.toDraft(
        {'action': 'ask', 'reply_text': 'Which model?'},
        receiptMetadata: {});
    expect(ask.decision, 'ask_clarification');
  });
  test('legacy policy serialization preserves hosted answer and review fields',
      () {
    for (final action in ['reply', 'ask', 'transfer', 'send_product']) {
      final original = JdV2Payload.toDraft({
        'action': action,
        'reply_text': 'Answer',
        'reason': 'Internal',
        'product_id': 'sku'
      }, receiptMetadata: {
        'jobId': 'job'
      });
      final raw = jsonDecode(original.rawJson) as Map<String, dynamic>;
      final rebuilt =
          AiDraft.fromJson(raw.cast<String, Object?>(), mediaBaseUrl: Uri());
      expect(rebuilt.reply, original.reply);
      expect(rebuilt.decision, original.decision);
      expect(rebuilt.model, original.model);
      expect(rebuilt.confidence, original.confidence);
      expect(rebuilt.riskLevel, original.riskLevel);
      expect(rebuilt.actions, original.actions);
      expect(jsonDecode(rebuilt.rawJson)['jd_v2']['jobId'], 'job');
    }
  });
  test('cached originals accept file URI paths from the native capture adapter',
      () async {
    final original = await image('has space.png');
    final result = await prepare([
      message('target', media: [
        {...original, 'path': Uri.file(original['path'] as String).toString()}
      ])
    ]);
    expect(result.files.single['path'], original['path']);
  });
  test(
      'historical video references validate every declared sample and discard local nonvisual IDs',
      () async {
    final frames = [
      for (var i = 0; i < 3; i++)
        await image('frame_0$i.jpg',
            source: 'jd_video_frame_1fps', id: 'sample-$i')
    ];
    await File('${temp.path}/sampling.json').writeAsString(jsonEncode({
      'fullRange': true,
      'frames': [
        for (var i = 0; i < frames.length; i++)
          {
            'name': 'frame_0$i.jpg',
            'bytes': 5,
          }
      ],
    }));
    final preview = {
      ...await image('preview.png', id: 'preview'),
      'is_partial': true
    };
    final historical = message('old', media: [
      {
        'type': 'video',
        'id': 'original-video',
        'path': '${temp.path}/original.mp4'
      },
      {'type': 'audio', 'id': 'audio', 'path': '${temp.path}/audio.wav'},
      preview,
      ...frames,
    ]);
    const refs = {
      'sample-0',
      'sample-1',
      'sample-2',
      'original-video',
      'audio',
      'preview',
      'already-hosted-id'
    };
    final result = await prepare([historical, message('target')], refs: refs);
    expect(result.files, hasLength(3));
    expect(result.request['referencedMediaIds'], ['already-hosted-id']);
    final oldEvent = (result.request['messages'] as List).first;
    expect(oldEvent['mediaIds'], hasLength(3));
    expect(oldEvent['mediaIds'], isNot(contains('original-video')));
    final incomplete = message('old', media: frames.sublist(0, 2));
    await expectLater(
        prepare([incomplete, message('target')],
            refs: {'sample-0', 'sample-1'}),
        throwsStateError);
  });
  test(
      'UTF8 budget drops oldest optional events while preserving all targets and explicit reference files',
      () async {
    final selectedImage = await image('reference.png', id: 'explicit-image');
    final result = await prepare([
      message('old-reference', body: 'Original visual', media: [selectedImage]),
      message('target', body: 'Question that must remain unchanged'),
      for (var i = 0; i < 30; i++) message('context-$i', body: '中' * 9999),
    ], refs: {
      'explicit-image'
    });
    final events = result.request['messages'] as List;
    expect(utf8.encode(jsonEncode(result.request)).length,
        lessThanOrEqualTo(200000));
    expect(events.map((e) => e['id']),
        containsAll(['target', 'old-reference', 'context-29']));
    expect(events.any((e) => e['id'] == 'context-0'), isFalse);
    expect(events.firstWhere((e) => e['id'] == 'target')['text'],
        'Question that must remain unchanged');
    expect(result.files, hasLength(1));
    expect(
        (result.request['media'] as List).single['messageId'], 'old-reference');
  });
  test(
      'verified speech stays derived text on its owning event without adding times or arbitrary analysis',
      () async {
    final frame = await image('frame_00.jpg', source: 'jd_video_frame_1fps');
    final media = [
      frame,
      {
        'type': 'video',
        'path': '${temp.path}/original.mp4',
        'description':
            'Plain scene analysis must be omitted. [Video speech transcript (zh): 打印机有异响] Extra reasoning omitted.'
      },
      {
        'type': 'audio',
        'path': '${temp.path}/audio.wav',
        'description':
            '[Video speech transcript (zh): 打印机有异响] [Speech transcript: second phrase]'
      },
      {
        'type': 'image',
        'path': frame['path'],
        'description':
            '[Speech transcript: unverified image guess] Plain image analysis'
      },
      {
        'type': 'audio',
        'is_loading_preview': true,
        'description': '[Speech transcript: loading guess]'
      },
    ];
    final result = await prepare(
        [message('target', body: 'Customer video', media: media)]);
    final events = result.request['messages'] as List;
    expect(events, hasLength(1));
    final event = events.single as Map;
    expect(event['id'], 'target');
    expect(event['role'], 'customer');
    expect(event['occurredAt'], '2026-11-18T04:00:00.000Z');
    final text = event['text'] as String;
    expect(text, startsWith('Customer video\n\n[Derived media transcript:'));
    expect(text, contains('not an original customer chat message'));
    expect(text, contains('[Video speech transcript (zh): 打印机有异响]'));
    expect(text, contains('[Speech transcript: second phrase]'));
    expect('打印机有异响'.allMatches(text), hasLength(1));
    expect(text, isNot(contains('analysis')));
    expect(text, isNot(contains('reasoning')));
    expect(text, isNot(contains('guess')));
    expect((result.request['media'] as List).single.containsKey('timestampMs'),
        isFalse);
    expect(result.files, hasLength(1));
    await expectLater(
        prepare([message('target', body: 'x' * 9990, media: media)]),
        throwsStateError);
  });
}
