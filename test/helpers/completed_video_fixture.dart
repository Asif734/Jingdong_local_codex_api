import 'dart:io';

import 'package:jd_automation/domain/capture_models.dart';

/// Valid fixture assets representing an already completed extraction. DB
/// ownership tests do not run decoders; the capture integration tests verify
/// that native extraction produces these phase conclusions.
Future<List<CapturedMedia>> completedVideoFixture(Directory root,
    {required String name}) async {
  final original =
      await File('test/fixtures/v35_media/unbound-video-original.mp4')
          .copy('${root.path}/$name.mp4');
  const image = 'test/fixtures/v35_media/unbound-video-cover.jpg';
  final first = await File(image).copy('${root.path}/$name-first.jpg');
  final tail = await File(image).copy('${root.path}/$name-tail.jpg');
  final cover = await File(image).copy('${root.path}/$name-cover.jpg');
  return [
    CapturedMedia(
        type: 'video',
        path: original.path,
        captureSource: 'jd_video_cache',
        description: '[Video audio: no audio stream]'),
    CapturedMedia(
        type: 'image',
        path: first.path,
        captureSource: 'jd_video_frame_1fps',
        originalName: 'video_frame_00s.jpg'),
    CapturedMedia(
        type: 'image',
        path: tail.path,
        captureSource: 'jd_video_frame_1fps',
        originalName: 'video_frame_tail.jpg'),
    CapturedMedia(
        type: 'image', path: cover.path, captureSource: 'jd_video_cover'),
  ];
}
