import 'package:flutter/services.dart';
import '../runtime/runtime_trace.dart';
import '../storage/capture_evidence_store.dart';
import 'evidence_coverage.dart';
import 'viewport_evidence.dart';

/// Capture a few overlapping history pages per lease. OCR starts on each
/// immutable frame; the viewport is restored once when the lease ends.
class BackfillDispatcher {
  BackfillDispatcher(
      {required this.store,
      required this.canRun,
      required this.canVisit,
      required this.withUi,
      required this.open,
      required this.scroll,
      required this.capture,
      this.burstPages = 3,
      this.record = RuntimeTrace.record});
  final CaptureEvidenceStore store;
  final int burstPages;
  final bool Function() canRun;
  final Future<bool> Function(String) canVisit;
  final Future<void> Function(Future<void> Function()) withUi;
  final Future<void> Function(String) open;
  final Future<void> Function(String, int) scroll;
  final Future<ViewportEvidence?> Function(String, DateTime) capture;
  final void Function(String, Map<String, Object?>) record;

  Future<void> runOnePage() async {
    if (!canRun()) return;
    final jobs = await store.pendingBackfills();
    // Restoration must also run after the last page or after OCR marks a gap
    // covered. Those jobs no longer appear in pendingBackfills().
    for (final restore in await store.dueRestorations()) {
      final customer = restore['customer']! as String;
      if (jobs.any((job) => job['customer'] == customer) ||
          !await canVisit(customer)) {
        continue;
      }
      if (!canRun()) return;
      try {
        await withUi(() async {
          if (!canRun() || !await canVisit(customer)) return;
          await open(customer);
          await scroll(customer, -10000);
          await store.setRestore(customer, false);
          record('evidence.backfill_restored',
              {'customer': customer, 'restoreOnly': true});
        });
      } catch (error, stack) {
        await store.deferBackfill(customer);
        record('evidence.backfill_failed', {
          'customer': customer,
          'stage': 'restore_only',
          'error': '$error',
          'stack': '$stack',
          'errorCode': error is PlatformException
              ? error.code
              : error.runtimeType.toString()
        });
      }
      return;
    }
    for (final job in jobs) {
      final customer = job['customer']! as String;
      if (!await canVisit(customer)) continue;
      if (!canRun()) return;
      final cutoff = DateTime.fromMillisecondsSinceEpoch(
          job['cutoff_ms']! as int,
          isUtc: true);
      final fields = <String, Object?>{
        'customer': customer,
        'cutoffMs': cutoff.millisecondsSinceEpoch,
        'page': (job['pages']! as int) + 1
      };
      final elapsed = Stopwatch()..start();
      var stage = 'queue';
      var attempted = false;
      var charged = false;
      try {
        await withUi(() async {
          if (!canRun() || !await canVisit(customer)) return;
          // Accurate OCR can cover or replace this job while it waits for UI.
          final fresh = (await store.pendingBackfills()).where((row) =>
              row['customer'] == customer &&
              row['cutoff_ms'] == job['cutoff_ms'] &&
              row['pages'] == job['pages']);
          if (fresh.isEmpty) return;
          stage = 'open';
          await open(customer);
          // If a prior process died mid-scroll, begin from a known bottom.
          if (!canRun()) return;
          stage = 'restore_before';
          if ((await store.restoreCutoffs()).containsKey(customer)) {
            await scroll(customer, -10000);
            await store.setRestore(customer, false);
          }
          if (!canRun()) return;
          record('evidence.backfill_started', fields);
          // Persist BEFORE the native scroll: a crash can never silently leave
          // the next normal capture looking at an old part of the conversation.
          await store.setRestore(customer, true);
          try {
            var page = job['pages']! as int;
            final step = job['step_pixels']! as int;
            for (var index = 0; index < burstPages && canRun(); index++) {
              final pending = (await store.pendingBackfills()).any((row) =>
                  row['customer'] == customer &&
                  row['cutoff_ms'] == cutoff.millisecondsSinceEpoch &&
                  row['pages'] == page);
              if (!pending ||
                  !canRun() ||
                  !await canVisit(customer) ||
                  !canRun()) {
                break;
              }
              stage = 'scroll';
              charged = false;
              await scroll(
                  customer,
                  index == 0
                      ? EvidenceCoverage.scrollPixels(page, stepPixels: step)
                      : step);
              if (!canRun() || !await canVisit(customer) || !canRun()) break;
              stage = 'capture';
              attempted = true;
              // Count an attempted screenshot even when the file save fails,
              // but don't skip a page interrupted before it was captured.
              try {
                final frame = await capture(customer, cutoff);
                if (frame == null) throw StateError('backfill_frame_not_saved');
                record('evidence.backfill_page_saved', {
                  ...fields,
                  'page': page + 1,
                  'evidenceId': frame.id,
                  'elapsedMs': elapsed.elapsedMilliseconds
                });
              } finally {
                charged = true;
                await store.backfillAttempt(customer, cutoff: cutoff);
              }
              page++;
            }
          } finally {
            final previousStage = stage;
            stage = 'restore_after';
            await scroll(customer, -10000);
            await store.setRestore(customer, false);
            record('evidence.backfill_restored', fields);
            stage = previousStage;
          }
        });
        if (attempted && await store.coverageState(customer) == 'exhausted') {
          record('evidence.backfill_exhausted', {
            ...fields,
            'reason': 'page_limit',
            'waitsForVerifiedProgress': true,
            'coverageConfirmed': false
          });
        }
      } catch (error, stack) {
        await store.deferBackfill(customer);
        if (!charged &&
            (error is! PlatformException ||
                !const {
                  'qianniu_not_frontmost',
                  'composer_not_empty',
                  'scroll_verification_failed',
                  'snapshot_customer_changed'
                }.contains(error.code))) {
          await store.backfillAttempt(customer, cutoff: cutoff);
        }
        record('evidence.backfill_failed', {
          ...fields,
          'stage': stage,
          'error': '$error',
          'stack': '$stack',
          'elapsedMs': elapsed.elapsedMilliseconds,
          'errorCode': error is PlatformException
              ? error.code
              : error.runtimeType.toString()
        });
      }
      // New unread work and send deadlines take precedence over the next job.
      return;
    }
  }
}
