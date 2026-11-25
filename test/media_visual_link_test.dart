import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/conversation_file_store.dart';
import 'package:jd_automation/storage/media_visual_matcher.dart';

Future<Uint8List> picture(
    {bool decorated = false, bool different = false, bool flat = false}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
  final offset = decorated ? const ui.Offset(12, 26) : ui.Offset.zero;
  canvas.save();
  canvas.translate(offset.dx, offset.dy);
  final paint = ui.Paint();
  if (flat) {
    paint.color = const ui.Color(0xffcc0000);
  } else {
    paint.shader = ui.Gradient.linear(
        ui.Offset.zero,
        const ui.Offset(200, 260),
        different
            ? [const ui.Color(0xff20d050), const ui.Color(0xff2020b0)]
            : [const ui.Color(0xff304050), const ui.Color(0xffb0a080)]);
  }
  canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 200, 260), paint);
  if (!flat) {
    canvas.drawCircle(
        different ? const ui.Offset(140, 190) : const ui.Offset(70, 65),
        42,
        ui.Paint()..color = const ui.Color(0xffe0d090));
    canvas.drawRect(const ui.Rect.fromLTWH(30, 150, 130, 45),
        ui.Paint()..color = const ui.Color(0xff6a5040));
  }
  canvas.restore();
  final scene = recorder.endRecording();
  final image =
      await scene.toImage(decorated ? 244 : 200, decorated ? 312 : 260);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
    scene.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ConversationFileStore store;
  final at = DateTime.utc(2026, 11, 1, 6, 20, 33);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_pixel_link_');
    store = ConversationFileStore(root);
  });
  tearDown(() => root.delete(recursive: true));
  Future<void> save(Uint8List bytes,
      {bool partial = false, String? turn = 'turn-a'}) async {
    final path = await store.saveMedia(
        userId: 'a', filename: 'fixture.png', bytes: bytes);
    await store.appendCapture(CapturedConversation(
        stableKey: 'a',
        customerName: 'a',
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: 'canonical',
              direction: 'incoming',
              body: 'image',
              sentAt: at,
              observationTurnKey: turn,
              axPath: 'fixture',
              media: [
                CapturedMedia(
                    type: 'image',
                    path: path,
                    isPartial: partial,
                    captureSource:
                        partial ? 'verified_window_crop' : 'jd_image_cache')
              ])
        ]));
  }

  test('condition trace preserves measured pixel score and exact gate',
      () async {
    await save(await picture());
    final events = <Map<String, Object?>>[];
    final matcher = MediaVisualMatcher(store, record: (event, fields) {
      if (event == 'media.condition') events.add(fields);
    });
    final match = await matcher.find(
        customer: 'a', bytes: await picture(), sentAt: at, observedAt: at);
    expect(match, isNotNull);
    final compared = events
        .singleWhere((e) => e['conditionId'] == 'representation.pixel_error');
    expect(compared['messageId'], match!.messageId);
    expect(compared['customer'], 'a');
    expect(compared['expression'], 'pixelError <= 0.025');
    expect((compared['actual'] as Map)['pixelError'], lessThanOrEqualTo(.025));
    expect((compared['threshold'] as Map)['maximumPixelError'], .025);
    expect(compared['passed'], isTrue);
    expect(events.last['conditionId'], 'representation.unique_source');
    expect(events.last['passed'], isTrue);
  });

  test(
      'decorated crop binds the same-clock original and a distinct image does not',
      () async {
    await save(await picture());
    final matcher = MediaVisualMatcher(store);
    final match = await matcher.find(
        customer: 'a',
        bytes: await picture(decorated: true),
        sentAt: at,
        observedAt: at);
    expect(match?.messageId, 'canonical');
    expect(
        (await matcher.find(
                customer: 'a',
                bytes: await picture(decorated: true),
                observedAt: at))
            ?.messageId,
        'canonical');
    expect(
        await matcher.find(
            customer: 'a',
            bytes: await picture(different: true, decorated: true),
            sentAt: at,
            observedAt: at),
        isNull);
  });
  test('another verified send time, customer or unread turn cannot be merged',
      () async {
    await save(await picture());
    final matcher = MediaVisualMatcher(store);
    final bytes = await picture(decorated: true);
    expect(
        await matcher.find(
            customer: 'a',
            bytes: bytes,
            sentAt: at.add(const Duration(seconds: 1)),
            observedAt: at),
        isNull);
    expect(
        await matcher.find(
            customer: 'b', bytes: bytes, sentAt: at, observedAt: at),
        isNull);
    expect(
        await matcher.find(
            customer: 'a', bytes: bytes, turnKey: 'turn-b', observedAt: at),
        isNull);
  });
  test('flat-color content cannot establish media identity', () async {
    await save(await picture(flat: true));
    expect(
        await MediaVisualMatcher(store).find(
            customer: 'a',
            bytes: await picture(flat: true, decorated: true),
            sentAt: at,
            observedAt: at),
        isNull);
  });
  test('late original promotes a crop without changing durable message ID',
      () async {
    await save(await picture(decorated: true), partial: true);
    final bytes = await picture();
    final match = await MediaVisualMatcher(store).find(
        customer: 'a',
        bytes: bytes,
        sentAt: at,
        observedAt: at,
        candidateOriginal: true);
    expect(match?.messageId, 'canonical');
    expect(match?.partial, isTrue);
    final path = await store.saveMedia(
        userId: 'a', filename: 'original.png', bytes: bytes);
    expect(
        await store.promoteMedia(
            'a',
            'canonical',
            CapturedMessage(
                stableId: 'canonical',
                direction: 'incoming',
                body: 'original',
                axPath: 'cache',
                media: [
                  CapturedMedia(
                      type: 'image',
                      path: path,
                      captureSource: 'jd_image_cache')
                ])),
        isTrue);
    final messages = (await store.read('a'))!['messages'] as List;
    expect(messages, hasLength(1));
    expect(messages.single['id'], 'canonical');
    expect(messages.single['media'][0]['path'], path);
    expect(messages.single['media_alternates'], hasLength(1));
  });
}
