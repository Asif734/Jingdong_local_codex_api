import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/media_caption_dependency.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/capture/ocr_image_candidate_selector.dart';
import 'package:jd_automation/capture/video_frame_extractor.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('one immutable current media owner never borrows a later recovery clock',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v37_cutoff_');
    final db = CaptureDatabase(storageRoot: root);
    try {
      final at = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch,
          isUtc: true);
      final session = await db.beginAutomationSession(startedAt: at);
      final store = CaptureEvidenceStore(db);
      await store.beginSession(sessionId: session, startedAt: at);
      Future<ViewportEvidence> frame(String id) async {
        final image = File('${root.path}/$id.png');
        await image.writeAsBytes([1]);
        final manifest = File('${root.path}/$id.json');
        final evidence = ViewportEvidence({
          'evidenceId': id,
          'customer': 'buyer',
          'automationSessionId': session,
          'capturedAtMs':
              at.add(const Duration(seconds: 1)).millisecondsSinceEpoch,
          'imagePath': image.path,
          'manifestPath': manifest.path,
          'capturePurpose': 'active_discovery',
          'replyActivationAllowed': true
        });
        await manifest.writeAsString(evidence.toJson());
        await store.record(evidence);
        return evidence;
      }

      final owner = await frame('current-owner');
      final first = at.add(const Duration(seconds: 2));
      expect(
          await store.backfillCutoffFor(owner, currentSignalAt: first), first);
      for (final seconds in [28, 32, 36, 120]) {
        expect(
            await store.backfillCutoffFor(owner,
                currentSignalAt: at.add(Duration(seconds: seconds))),
            first);
      }
      final claimed = (await store.claim(mediaOnly: false))!;
      expect(claimed.id, owner.id);
      expect(await store.requestMediaTypeRecheck(owner.id), isTrue);
      await store.pin(
          owner.withPinnedMedia({'kind': 'video', 'evidenceFile': 'owned'}));
      expect(
          await store.backfillCutoffFor((await store.lookup(owner.id))!,
              currentSignalAt: at.add(const Duration(minutes: 3))),
          first);
      await store.complete(claimed);
      final refreshed = await store.claim(mediaOnly: false);
      expect(refreshed?.id, owner.id,
          reason: 'A late original releases the old processing lease as '
              'captured; its existing type recheck must survive that refresh');
      expect(refreshed!.pinnedMedia, isNotNull);
      expect(refreshed.metadata['mediaTypeRecheckRequested'], isTrue);
      await store.complete(refreshed);
      expect((await store.claim(mediaOnly: true))?.id, owner.id,
          reason: 'A type hint racing the current worker must remain a durable '
              'exact-frame recheck, not disappear before completion');
      await store.complete((await store.lookup(owner.id))!);
      final newBubble = await frame('another-real-bubble');
      final next = at.add(const Duration(seconds: 40));
      expect(
          await store.backfillCutoffFor(newBubble, currentSignalAt: next), next,
          reason:
              'Freezing one owner cannot freeze another message of this customer');
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });

  test(
      'recorded Nov8 caption waits for its unique adjacent card, not unrelated questions',
      () async {
    final inspection = OcrInspection.fromMap(Map<String, Object?>.from(
        jsonDecode(await File('test/fixtures/v37_media/nov8-caption-frame.json')
            .readAsString()) as Map));
    const buyer = 'jd_41aeec7741d05';
    final cards = const OcrImageCandidateSelector().select(inspection, buyer,
        includeTextDense: true, allowUnlabeledLatestImage: true);
    expect(cards, hasLength(1));
    final text = const OcrCaptureExtractor()
        .analyze(inspection, excludedMediaRegions: cards)
        .capture!
        .messages;
    final caption =
        text.singleWhere((message) => message.body.contains('check my td630'));
    final cardAt = const OcrCaptureExtractor()
        .mediaClockForRegion(inspection, cards.single)
        .sentAt!;
    expect(
        text
            .where((message) =>
                message.direction == 'incoming' &&
                message.sentAt != null &&
                !message.sentAt!.isBefore(cardAt))
            .map((message) => message.body),
        [caption.body],
        reason: 'Power/paper/pause/long-press labels inside the video card '
            'are media evidence, never extra customer message records');
    final owners = {cards.single: 'exact-receipt'};
    expect(MediaCaptionDependency.infer(inspection, buyer, text, owners),
        {caption.stableId: 'exact-receipt'});
    final extra = const OcrVisualRegion(
        x: .48, y: .49, width: .1, height: .12, confidence: 1);
    expect(
        MediaCaptionDependency.infer(
            inspection, buyer, text, {...owners, extra: 'another-receipt'}),
        isEmpty,
        reason: 'Multiple media are not assigned by closest clock');
    final independent = inspection.withObservations(inspection.observations
        .map((line) => line.text.contains('check my td630')
            ? OcrObservation(
                text: 'Check USB connection and warranty',
                confidence: line.confidence,
                x: line.x,
                y: line.y,
                width: line.width,
                height: line.height)
            : line)
        .toList());
    final independentText = const OcrCaptureExtractor()
        .analyze(independent, excludedMediaRegions: cards)
        .capture!
        .messages;
    expect(
        MediaCaptionDependency.infer(
            independent, buyer, independentText, owners,
            independentMessageIds:
                independentText.map((m) => m.stableId).toSet()),
        isEmpty);
  });

  test(
      'actual Nov8 first frame survives sampling and incomplete caches rebuild',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v37_frames_');
    try {
      final video = await File('test/fixtures/v37_media/nov8-first-second.mp4')
          .copy('${root.path}/video.mp4');
      final digest = sha256.convert(await video.readAsBytes()).toString();
      final legacy =
          await Directory('${root.path}/frames_${digest.substring(0, 16)}')
              .create();
      await File('${legacy.path}/frame_01.jpg').writeAsBytes([1, 2, 3]);
      final result = await const VideoFrameExtractor().extract(video.path);
      expect(result.framePaths.first, endsWith('frame_00.jpg'));
      expect(result.framePaths.length, inInclusiveRange(2, 20));
      expect(result.framePaths.first, contains('_full_v3'));
      Future<List<int>> rgba(String path) async {
        final codec =
            await ui.instantiateImageCodec(await File(path).readAsBytes());
        final image = (await codec.getNextFrame()).image;
        final bytes =
            await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final data = bytes!.buffer.asUint8List().toList();
        image.dispose();
        codec.dispose();
        return data;
      }

      final expected = await rgba('test/fixtures/v37_media/nov8-t0.png');
      final actual = await rgba(result.framePaths.first);
      expect(actual.length, expected.length);
      var difference = 0;
      for (var i = 0; i < actual.length; i++) {
        difference += (actual[i] - expected[i]).abs();
      }
      expect(difference / actual.length, lessThan(4),
          reason: 'Sample 00 must be the decoded t0, not fps=1\'s later frame');
      await File(result.framePaths.first).delete();
      final repaired = await const VideoFrameExtractor().extract(video.path);
      expect(await File(repaired.framePaths.first).length(), greaterThan(0));
      expect(
          await File('${legacy.path}/frame_01.jpg').readAsBytes(), [1, 2, 3]);
    } finally {
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);

  test(
      'a longer video samples its actual end rather than only its first twenty seconds',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v37_tail_');
    try {
      final video = '${root.path}/long.mp4';
      final made = await Process.run('/opt/homebrew/bin/ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'color=blue:s=32x32:r=1:d=28',
        '-f',
        'lavfi',
        '-i',
        'color=red:s=32x32:r=1:d=1',
        '-filter_complex',
        '[0:v][1:v]concat=n=2:v=1:a=0',
        '-c:v',
        'libx264',
        '-y',
        video
      ]);
      expect(made.exitCode, 0);
      final result = await const VideoFrameExtractor().extract(video);
      expect(result.framePaths.length, lessThanOrEqualTo(20));
      final codec = await ui.instantiateImageCodec(
          await File(result.framePaths.last).readAsBytes());
      final image = (await codec.getNextFrame()).image;
      final bytes =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
              .buffer
              .asUint8List();
      expect(bytes[0], greaterThan(200));
      expect(bytes[2], lessThan(30),
          reason: 'The late red final second must be present');
      image.dispose();
      codec.dispose();
    } finally {
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
