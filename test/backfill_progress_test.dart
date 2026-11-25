import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

void main() {
  test(
      'verified older pages extend recovery; repeated pages cannot reopen exhaustion',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_progress_');
    final db = CaptureDatabase(storageRoot: root);
    final store = CaptureEvidenceStore(db);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final cutoff = DateTime.utc(2026, 11, 1, 6);
    await store.requestBackfill('a', cutoff);
    for (var i = 0; i < 3; i++) {
      await store.backfillAttempt('a', cutoff: cutoff);
    }
    expect(await store.coverageState('a'), 'exhausted');
    final oldest = cutoff.add(const Duration(minutes: 1));
    expect(await store.reportBackfillProgress('a', cutoff, oldest), isTrue);
    expect(await store.coverageState('a'), 'pending');
    for (var i = 0; i < 3; i++) {
      await store.backfillAttempt('a', cutoff: cutoff);
    }
    expect(await store.coverageState('a'), 'exhausted');
    expect(await store.reportBackfillProgress('a', cutoff, oldest), isFalse);
    expect(await store.coverageState('a'), 'exhausted');
    expect(
        await store.reportBackfillProgress(
            'a', cutoff, cutoff.add(const Duration(seconds: 30))),
        isTrue);
    for (var i = 0; i < 3; i++) {
      await store.backfillAttempt('a', cutoff: cutoff);
    }
    expect(
        await store.reportBackfillProgress(
            'a', cutoff, cutoff.add(const Duration(seconds: 15))),
        isTrue);
    for (var i = 0; i < 3; i++) {
      await store.backfillAttempt('a', cutoff: cutoff);
    }
    expect(
        await store.reportBackfillProgress(
            'a', cutoff, cutoff.add(const Duration(seconds: 5))),
        isTrue);
    expect(await store.coverageState('a'), 'exhausted');
    await store.covered('a', cutoff: cutoff);
    expect(await store.reportBackfillProgress('a', cutoff, oldest), isFalse);
    expect(await store.coverageState('a'), 'covered');
  });
}
