import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/video_audio_extractor.dart';
import 'package:jd_automation/capture/video_frame_extractor.dart';
import 'package:jd_automation/runtime/managed_media_processes.dart';

Future<int> waitForPid(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) {
      final pid = int.tryParse((await file.readAsString()).trim());
      if (pid != null) return pid;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Owned media child did not start');
}

Future<bool> isAlive(int pid) async =>
    (await Process.run('/bin/kill', ['-0', '$pid'])).exitCode == 0;

void main() {
  late Directory temporary;
  late ManagedMediaProcesses manager;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('media_stop_test_');
    manager = ManagedMediaProcesses();
  });
  tearDown(() async {
    await manager.cancelRun();
    await temporary.delete(recursive: true);
  });

  test('Stop reaps only owned children and a new run executes fresh work',
      () async {
    final unrelated = await Process.start('/bin/sleep', ['30']);
    addTearDown(() async {
      unrelated.kill(ProcessSignal.sigkill);
      await unrelated.exitCode;
    });
    final token = manager.beginRun();
    final pidFile = File('${temporary.path}/pid');
    final work = token.execute('/bin/sh', [
      '-c',
      'echo \$\$ > "\$1"; exec /bin/sleep 30',
      'media-child',
      pidFile.path,
    ]);
    final cancelled = expectLater(work, throwsA(isA<MediaProcessCancelled>()));
    final pid = await waitForPid(pidFile);
    expect(await isAlive(pid), isTrue);
    await manager.cancelRun();
    await cancelled;
    expect(await isAlive(pid), isFalse);
    expect(await isAlive(unrelated.pid), isTrue);
    final fresh = manager.beginRun();
    final result = await fresh.execute('/bin/echo', ['fresh']);
    expect(result.exitCode, 0);
    expect(result.stdout, 'fresh\n');
  });

  test('Stop covers a child whose Process.start is still pending', () async {
    final token = manager.beginRun();
    final work = token.execute('/bin/sleep', ['30']);
    final cancelled = expectLater(work, throwsA(isA<MediaProcessCancelled>()));
    await manager.cancelRun().timeout(const Duration(seconds: 4));
    await cancelled;
    expect(token.isCancelled, isTrue);
  });

  test('Stop escalates to kill for a child that ignores termination', () async {
    final token = manager.beginRun();
    final pidFile = File('${temporary.path}/pid');
    final work = token.execute('/bin/sh', [
      '-c',
      'trap "" TERM; echo \$\$ > "\$1"; while :; do :; done',
      'media-child',
      pidFile.path,
    ]);
    final cancelled = expectLater(work, throwsA(isA<MediaProcessCancelled>()));
    final pid = await waitForPid(pidFile);
    await manager.cancelRun().timeout(const Duration(seconds: 4));
    await cancelled;
    expect(await isAlive(pid), isFalse);
  });

  test('an old pipeline cannot start its next child after restart', () async {
    final token = manager.beginRun();
    final marker = File('${temporary.path}/unexpected');
    final continuePipeline = Completer<void>();
    final work = token.run(() async {
      await continuePipeline.future;
      return manager.runCurrent(
          () => manager.captureRun().execute('/usr/bin/touch', [marker.path]));
    });
    final cancelled = expectLater(work, throwsA(isA<MediaProcessCancelled>()));
    await manager.cancelRun();
    manager.beginRun();
    continuePipeline.complete();
    await cancelled;
    expect(await marker.exists(), isFalse);
  });

  for (final audio in [false, true]) {
    test(
        '${audio ? 'audio' : 'frame'} cancellation stops probe and later steps',
        () async {
      final token = manager.beginRun();
      final pidFile = File('${temporary.path}/pid');
      final marker = File('${temporary.path}/unexpected_ffmpeg');
      final video = File('${temporary.path}/customer.mp4');
      await video.writeAsBytes([1, 2, 3]);
      final probe = File('${temporary.path}/ffprobe');
      await probe.writeAsString(
          '#!/bin/sh\necho \$\$ > "${pidFile.path}"\nexec /bin/sleep 30\n');
      final ffmpeg = File('${temporary.path}/ffmpeg');
      await ffmpeg
          .writeAsString('#!/bin/sh\n/usr/bin/touch "${marker.path}"\n');
      await Process.run('/bin/chmod', ['+x', probe.path, ffmpeg.path]);
      final work = token.run(() => audio
          ? VideoAudioExtractor(
                  ffprobeExecutable: probe.path, ffmpegExecutable: ffmpeg.path)
              .extract(video.path)
          : VideoFrameExtractor(
                  ffprobeExecutable: probe.path, ffmpegExecutable: ffmpeg.path)
              .extract(video.path));
      final cancelled =
          expectLater(work, throwsA(isA<MediaProcessCancelled>()));
      final pid = await waitForPid(pidFile);
      await manager.cancelRun();
      manager.beginRun();
      await cancelled;
      expect(await isAlive(pid), isFalse);
      expect(await marker.exists(), isFalse);
    });
  }
}
