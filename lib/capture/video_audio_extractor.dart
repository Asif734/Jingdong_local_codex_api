import 'dart:io';

import 'package:path/path.dart' as p;
import '../runtime/app_runtime.dart';
import '../runtime/managed_media_processes.dart';

class ExtractedVideoAudio {
  const ExtractedVideoAudio({
    required this.hasAudioStream,
    required this.hasAudibleContent,
    this.audioPath,
    this.meanVolumeDb,
  });

  final bool hasAudioStream;
  final bool hasAudibleContent;
  final String? audioPath;
  final double? meanVolumeDb;
}

class VideoAudioExtractor {
  const VideoAudioExtractor({this.ffmpegExecutable, this.ffprobeExecutable});

  static const audibleThresholdDb = -55.0;
  final String? ffmpegExecutable;
  final String? ffprobeExecutable;

  List<String> probeArguments(String inputPath) => [
        '-v',
        'error',
        '-select_streams',
        'a:0',
        '-show_entries',
        'stream=index',
        '-of',
        'csv=p=0',
        inputPath,
      ];

  List<String> extractionArguments(String inputPath, String outputPath) => [
        '-hide_banner',
        '-loglevel',
        'error',
        '-i',
        inputPath,
        '-map',
        '0:a:0',
        '-vn',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-c:a',
        'pcm_s16le',
        '-y',
        outputPath,
      ];

  List<String> volumeArguments(String audioPath) => [
        '-hide_banner',
        '-i',
        audioPath,
        '-af',
        'volumedetect',
        '-f',
        'null',
        '-',
      ];

  Future<ExtractedVideoAudio> extract(String videoPath) async {
    final run = ManagedMediaProcesses.shared.captureRun();
    run.throwIfCancelled();
    final video = File(videoPath);
    if (!await video.exists()) {
      throw VideoAudioExtractionException('Video is missing: $videoPath');
    }
    final ffprobe = ffprobeExecutable ?? await _findExecutable('ffprobe');
    final probe = await run.execute(ffprobe, probeArguments(videoPath));
    if (probe.exitCode != 0) {
      throw VideoAudioExtractionException(
          'FFprobe could not inspect the video audio: ${probe.stderr}');
    }
    if (probe.stdout.toString().trim().isEmpty) {
      return const ExtractedVideoAudio(
        hasAudioStream: false,
        hasAudibleContent: false,
      );
    }

    final ffmpeg = ffmpegExecutable ?? await _findExecutable('ffmpeg');
    final audioPath = p.join(video.parent.path,
        '${p.basenameWithoutExtension(videoPath)}_audio.wav');
    final extraction =
        await run.execute(ffmpeg, extractionArguments(videoPath, audioPath));
    if (extraction.exitCode != 0 || !await File(audioPath).exists()) {
      throw VideoAudioExtractionException(
          'FFmpeg could not extract the video audio: ${extraction.stderr}');
    }
    final volume = await run.execute(ffmpeg, volumeArguments(audioPath));
    final diagnostic = '${volume.stdout}\n${volume.stderr}';
    final match = RegExp(r'mean_volume:\s*(-?(?:\d+(?:\.\d+)?|inf))\s*dB')
        .firstMatch(diagnostic);
    final rawVolume = match?.group(1);
    if (volume.exitCode != 0 || rawVolume == null) {
      throw VideoAudioExtractionException(
          'FFmpeg could not establish whether the audio contains audible content.');
    }
    final meanVolume = rawVolume == '-inf'
        ? double.negativeInfinity
        : double.tryParse(rawVolume);
    if (meanVolume == null) {
      throw const VideoAudioExtractionException(
          'The audio volume result was invalid.');
    }
    run.throwIfCancelled();
    return ExtractedVideoAudio(
      hasAudioStream: true,
      hasAudibleContent: meanVolume >= audibleThresholdDb,
      audioPath: audioPath,
      meanVolumeDb: meanVolume,
    );
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
    throw VideoAudioExtractionException(
        '$name is required for customer-video audio analysis.');
  }
}

class VideoAudioExtractionException implements Exception {
  const VideoAudioExtractionException(this.message);
  final String message;

  @override
  String toString() => message;
}
