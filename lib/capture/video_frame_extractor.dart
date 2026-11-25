import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../runtime/app_runtime.dart';
import '../runtime/managed_media_processes.dart';

class ExtractedVideoFrames {
  const ExtractedVideoFrames({
    required this.videoPath,
    required this.sha256Digest,
    required this.framePaths,
  });

  final String videoPath;
  final String sha256Digest;
  final List<String> framePaths;
}

class VideoFrameExtractor {
  const VideoFrameExtractor({this.ffmpegExecutable, this.ffprobeExecutable});

  static const maximumFrames = 20;
  static const samplingContract = 'first-and-last-full-span-v3';
  final String? ffmpegExecutable;
  final String? ffprobeExecutable;

  List<String> buildArguments(String inputPath, String outputPattern,
          {double durationSeconds = 0}) =>
      [
        '-hide_banner',
        '-loglevel',
        'error',
        '-i',
        inputPath,
        '-vf',
        "select='eq(n,0)+gte(t-prev_selected_t,${durationSeconds > 19 ? durationSeconds / 19 : 1})'",
        '-fps_mode',
        'vfr',
        '-start_number',
        '0',
        '-frames:v',
        '${maximumFrames - 1}',
        '-q:v',
        '2',
        outputPattern,
      ];

  Future<ExtractedVideoFrames> extract(String videoPath) async {
    final run = ManagedMediaProcesses.shared.captureRun();
    run.throwIfCancelled();
    final video = File(videoPath);
    if (!await video.exists()) {
      throw VideoFrameExtractionException(
          'Downloaded video is missing: $videoPath');
    }
    final digest = (await sha256.bind(video.openRead()).first).toString();
    run.throwIfCancelled();
    final frameDirectory = Directory(
      p.join(video.parent.path, 'frames_${digest.substring(0, 16)}_full_v3'),
    );
    await frameDirectory.create(recursive: true);
    final existing = await _frames(frameDirectory);
    final manifest = File(p.join(frameDirectory.path, 'sampling.json'));
    if (await _completeCache(manifest, digest, existing)) {
      run.throwIfCancelled();
      return ExtractedVideoFrames(
        videoPath: videoPath,
        sha256Digest: digest,
        framePaths: existing.take(maximumFrames).toList(growable: false),
      );
    }

    // An interrupted/legacy cache is not proof that the first frame and all
    // declared samples were saved. Original video bytes remain untouched.
    for (final frame in existing) {
      run.throwIfCancelled();
      await File(frame).delete();
    }

    final executable = ffmpegExecutable ?? await _findExecutable('ffmpeg');
    final probe = await run
        .execute(ffprobeExecutable ?? await _findExecutable('ffprobe'), [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=nw=1:nk=1',
      videoPath
    ]);
    final duration = double.tryParse(probe.stdout.toString().trim());
    if (probe.exitCode != 0 ||
        duration == null ||
        !duration.isFinite ||
        duration <= 0) {
      throw const VideoFrameExtractionException(
          'The complete video duration could not be established.');
    }
    final pattern = p.join(frameDirectory.path, 'frame_%02d.jpg');
    final result = await run.execute(
      executable,
      buildArguments(videoPath, pattern, durationSeconds: duration),
    );
    if (result.exitCode != 0) {
      throw VideoFrameExtractionException(
        'FFmpeg failed to sample the customer video: ${result.stderr}',
      );
    }
    final sampled = await _frames(frameDirectory);
    if (sampled.isEmpty || p.basename(sampled.first) != 'frame_00.jpg') {
      throw const VideoFrameExtractionException(
          'The first video frame could not be decoded.');
    }
    final tailPath = p.join(frameDirectory.path,
        'frame_${sampled.length.toString().padLeft(2, '0')}.jpg');
    final tail = await run.execute(executable, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-sseof',
      '-${duration < 1 ? duration : 1}',
      '-i',
      videoPath,
      '-vf',
      'reverse',
      '-frames:v',
      '1',
      '-q:v',
      '2',
      '-y',
      tailPath
    ]);
    if (tail.exitCode != 0 || !await File(tailPath).exists()) {
      throw const VideoFrameExtractionException(
          'The end of the complete video could not be decoded.');
    }
    final frames = await _frames(frameDirectory);
    if (frames.isEmpty) {
      throw const VideoFrameExtractionException(
        'The customer video contained no decodable frames.',
      );
    }
    run.throwIfCancelled();
    await manifest.writeAsString(
        jsonEncode({
          'contract': samplingContract,
          'videoSha256': digest,
          'maximumFrames': maximumFrames,
          'fullRange': true,
          'durationSeconds': duration,
          'frames': [
            for (final frame in frames)
              {'name': p.basename(frame), 'bytes': await File(frame).length()}
          ]
        }),
        flush: true);
    run.throwIfCancelled();
    return ExtractedVideoFrames(
      videoPath: videoPath,
      sha256Digest: digest,
      framePaths: frames.take(maximumFrames).toList(growable: false),
    );
  }

  Future<bool> _completeCache(
      File manifest, String digest, List<String> frames) async {
    try {
      final value = jsonDecode(await manifest.readAsString()) as Map;
      final declared = (value['frames'] as List).whereType<Map>().toList();
      if (value['contract'] != samplingContract ||
          value['videoSha256'] != digest ||
          value['maximumFrames'] != maximumFrames ||
          value['fullRange'] != true ||
          declared.length < 2 ||
          declared.length > maximumFrames ||
          declared.length != frames.length ||
          p.basename(frames.first) != 'frame_00.jpg') {
        return false;
      }
      for (var i = 0; i < frames.length; i++) {
        if (declared[i]['name'] != p.basename(frames[i]) ||
            declared[i]['bytes'] != await File(frames[i]).length() ||
            (declared[i]['bytes'] as int) <= 0) {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    } on TypeError {
      return false;
    }
  }

  Future<List<String>> _frames(Directory directory) async {
    final paths = await directory
        .list()
        .where((entry) =>
            entry is File &&
            RegExp(r'^frame_\d{2}\.jpg$').hasMatch(p.basename(entry.path)))
        .map((entry) => entry.path)
        .toList();
    paths.sort();
    return paths;
  }

  Future<String> _findExecutable(String name) async {
    final bundled = await AppRuntime.bundledTool(name);
    if (bundled != null) return bundled;
    for (final candidate in [
      '/opt/homebrew/bin/$name',
      '/usr/local/bin/$name',
      '/usr/bin/$name',
    ]) {
      if (await File(candidate).exists()) return candidate;
    }
    throw VideoFrameExtractionException(
      '$name is required for complete customer-video analysis but was not found.',
    );
  }
}

class VideoFrameExtractionException implements Exception {
  const VideoFrameExtractionException(this.message);
  final String message;

  @override
  String toString() => message;
}
