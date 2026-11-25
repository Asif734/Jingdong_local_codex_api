import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ready customers rotate despite progress and preserve error backoff',
      () async {
    final root =
        await Directory.systemTemp.createTemp('jd_v49_backfill_fair_unit_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final started = DateTime.utc(2026, 11, 10);
    final cutoff = started.add(const Duration(seconds: 1));
    var current = started.add(const Duration(minutes: 10));
    final session = await db.beginAutomationSession(startedAt: started);
    final store = CaptureEvidenceStore(db, now: () => current);
    await store.beginSession(sessionId: session, startedAt: started);
    await store.requestBackfill('customer_A', cutoff);
    await store.requestBackfill('customer_B', cutoff);
    final served = <String, int>{};
    for (final expected in [
      'customer_A',
      'customer_B',
      'customer_A',
      'customer_B'
    ]) {
      expect((await store.pendingBackfills()).first['customer'], expected);
      await store.backfillAttempt(expected, cutoff: cutoff);
      final count = served.update(expected, (n) => n + 1, ifAbsent: () => 1);
      expect(
          await store.reportBackfillProgress(expected, cutoff,
              cutoff.add(Duration(seconds: 300 - count * 10))),
          isTrue);
      current = current.add(const Duration(milliseconds: 1));
    }
    await store.deferBackfill('customer_A');
    final sql = await db.database;
    final delayed = (await sql.query('capture_backfill',
            where: 'customer=?', whereArgs: ['customer_A']))
        .single['retry_at_ms'];
    await store.backfillAttempt('customer_A', cutoff: cutoff);
    expect(
        (await sql.query('capture_backfill',
                where: 'customer=?', whereArgs: ['customer_A']))
            .single['retry_at_ms'],
        delayed,
        reason: 'Charging a failed page must not erase the later error retry.');
    expect(
        (await store.pendingBackfills()).map((row) => row['customer']).toList(),
        ['customer_B']);
  });

  test(
      'verified older clocks continue beyond twelve pages without a spin reset',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_v49_backfill_unit_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final started = DateTime.utc(2026, 11, 10);
    final cutoff = started.add(const Duration(seconds: 1));
    final session = await db.beginAutomationSession(startedAt: started);
    final store = CaptureEvidenceStore(db);
    await store.beginSession(sessionId: session, startedAt: started);
    await store.requestBackfill('buyer', cutoff);
    DateTime? oldest;
    for (var page = 1; page <= 15; page++) {
      await store.backfillAttempt('buyer', cutoff: cutoff);
      oldest = cutoff.add(Duration(seconds: 300 - page * 10));
      expect(
          await store.reportBackfillProgress('buyer', cutoff, oldest), isTrue);
      final job = (await store.pendingBackfills()).single;
      expect(job['pages'], page);
      expect(job['page_limit']! as int, greaterThanOrEqualTo(page + 3));
    }
    for (var repeat = 0; repeat < 3; repeat++) {
      await store.backfillAttempt('buyer', cutoff: cutoff);
      expect(await store.reportBackfillProgress('buyer', cutoff, oldest!),
          isFalse);
    }
    expect(await store.pendingBackfills(), isEmpty);
    expect(await store.coverageState('buyer'), 'exhausted');
    await store.requestBackfill('buyer', cutoff, reopenCovered: true);
    expect(await store.pendingBackfills(), isEmpty,
        reason: 'An ordinary timer cannot reset a no-progress page budget.');
    expect(
        await store.reportBackfillProgress(
            'buyer', cutoff, oldest!.subtract(const Duration(seconds: 10))),
        isTrue);
    expect((await store.pendingBackfills()).single['pages'], 18);
    await store.covered('buyer', cutoff: cutoff);
    expect(await store.pendingBackfills(), isEmpty);
    expect(await store.coverageState('buyer'), 'covered');
  });
}
