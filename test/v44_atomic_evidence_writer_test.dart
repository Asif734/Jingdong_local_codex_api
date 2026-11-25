import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/storage/atomic_evidence_writer.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_v44_sidecar_');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('concurrent consumers share one atomic immutable evidence commit',
      () async {
    final path = '${root.path}/frame.ocr.json';
    final payload =
        jsonEncode({'evidenceId': 'frame', 'observations': 'a' * 10000});
    final writes = List.generate(
        40, (_) => AtomicEvidenceWriter.write(path, payload, session: 'run1'));
    expect(writes.every((future) => identical(future, writes.first)), isTrue);
    await Future.wait(writes);
    expect(await File(path).readAsString(), payload);
    expect(await root.list().map((f) => f.path).toList(), [path]);
    // A later complete recognition may replace a sidecar; only overlap is
    // coalesced, not all future work for that filename.
    await AtomicEvidenceWriter.write(path, '{}', session: 'run1');
    expect(await File(path).readAsString(), '{}');
  });

  test('a failed shared commit propagates and does not poison a retry',
      () async {
    final directory = Directory('${root.path}/missing');
    final path = '${directory.path}/frame.ocr.json';
    final first = AtomicEvidenceWriter.write(path, '{}', session: 'run1');
    final second = AtomicEvidenceWriter.write(path, '{}', session: 'run1');
    expect(identical(first, second), isTrue);
    await expectLater(first, throwsA(isA<FileSystemException>()));
    await expectLater(second, throwsA(isA<FileSystemException>()));
    await directory.create();
    await AtomicEvidenceWriter.write(path, '{}', session: 'run1');
    expect(await File(path).readAsString(), '{}');
  });
}
