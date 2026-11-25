import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/customer_media_inventory.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';
import 'package:jd_automation/storage/media_message_registrar.dart';

class _SessionDatabase extends CaptureDatabase {
  @override
  String get currentAutomationSessionId => 'registrar-test-session';
}

/// A controlled discovery boundary; there are no pixels, native calls, cache
/// lookups or media-analysis services in these lock tests.
class _DiscoveryAudit extends MediaCaptureAudit {
  _DiscoveryAudit(super.database,
      {required this.starts, this.blockId, this.blockGroupId, this.failId});

  final List<String> starts;
  final String? blockId;
  final String? blockGroupId;
  final String? failId;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String> discover(ViewportEvidence evidence, OcrVisualRegion region,
      {OcrInspection? inspection,
      Iterable<OcrVisualRegion>? physicalCards}) async {
    starts.add(evidence.id);
    if (evidence.id == blockId) {
      entered.complete();
      await release.future;
    }
    if (evidence.id == failId) throw StateError('controlled-discovery-failure');
    return 'observation:${evidence.id}';
  }

  @override
  Future<Map<String, Object?>> groupUnbound(
      ViewportEvidence evidence, OcrVisualRegion region, String id,
      {OcrInspection? inspection,
      Iterable<OcrVisualRegion>? physicalCards}) async {
    if (evidence.id == blockGroupId) {
      entered.complete();
      await release.future;
    }
    return {
      'observationGroupId': 'one-video-group',
      'state': 'discovered',
      'videoOccurrenceProven': true,
    };
  }
}

class _ObservationInventory extends CustomerMediaInventory {
  _ObservationInventory(super.database);
  final observed = <String>[];

  @override
  Future<String> observe(
      {required String customer,
      required String evidenceId,
      required DateTime observedAt,
      required DateTime? senderAt,
      required int slot,
      required List<double> region,
      bool current = true,
      String? occurrenceKey,
      String? parentReceiptId}) async {
    observed.add(evidenceId);
    return 'receipt:$customer:$evidenceId';
  }

  @override
  Future<MediaParent?> resolveParent(String customer,
          {String? receiptId,
          String? messageId,
          bool requireCurrentSession = false}) async =>
      null;
}

const _card =
    OcrVisualRegion(x: .4, y: .2, width: .2, height: .3, confidence: 1);

Future<MediaMessageRegistration> _register(
    MediaMessageRegistrar registrar, String id,
    {String customer = 'customer-a', void Function()? checkCurrent}) {
  final at = DateTime.utc(2026, 11, 9, 3, 44);
  return registrar.register(
      evidence: ViewportEvidence({
        'evidenceId': id,
        'customer': customer,
        'capturedAtMs': at.millisecondsSinceEpoch,
        'automationSessionId': 'registrar-test-session',
        'replyActivationAllowed': true,
      }),
      inspection: OcrInspection(
          image: Uint8List(0),
          imageWidth: 100,
          imageHeight: 100,
          windowTitle: 'controlled registration',
          recognizedText: '',
          observations: const [],
          capturedAt: at,
          activeCustomerId: customer),
      cards: const [_card],
      visibleText: const [],
      registerOnly: false,
      checkCurrent: checkCurrent);
}

void main() {
  test('two registrar instances serialize one customer before discovery',
      () async {
    final db = _SessionDatabase();
    final starts = <String>[];
    final audit = _DiscoveryAudit(db, starts: starts, blockId: 'first');
    final inventory = _ObservationInventory(db);
    final first = _register(
        MediaMessageRegistrar(db, audit: audit, inventory: inventory), 'first');
    await audit.entered.future;
    final second = _register(
        MediaMessageRegistrar(db,
            audit: _DiscoveryAudit(db, starts: starts), inventory: inventory),
        'second');
    await Future<void>.delayed(Duration.zero);
    expect(starts, ['first']);
    expect(inventory.observed, isEmpty);
    audit.release.complete();
    final results = await Future.wait([first, second]);
    expect(starts, ['first', 'second']);
    expect(inventory.observed, ['first', 'second']);
    for (final result in results) {
      expect(result.occurrences[_card], 'bubble:one-video-group');
      expect(result.createdAdmissions, isEmpty);
    }
  });

  test('failed registration releases ownership for the next observation',
      () async {
    final db = _SessionDatabase();
    final starts = <String>[];
    final audit = _DiscoveryAudit(db,
        starts: starts, blockId: 'failed', failId: 'failed');
    final inventory = _ObservationInventory(db);
    final registrar =
        MediaMessageRegistrar(db, audit: audit, inventory: inventory);
    final first = _register(registrar, 'failed');
    final failure = expectLater(first, throwsStateError);
    await audit.entered.future;
    final second = _register(registrar, 'following');
    audit.release.complete();
    await failure;
    final result = await second.timeout(const Duration(seconds: 1));
    expect(starts, ['failed', 'following']);
    expect(inventory.observed, ['following']);
    expect(result.createdAdmissions, isEmpty);
  });

  test('one customer registration never blocks another customer', () async {
    final db = _SessionDatabase();
    final starts = <String>[];
    final audit = _DiscoveryAudit(db, starts: starts, blockId: 'blocked-a');
    final inventory = _ObservationInventory(db);
    final registrar =
        MediaMessageRegistrar(db, audit: audit, inventory: inventory);
    final first = _register(registrar, 'blocked-a');
    await audit.entered.future;
    try {
      final second =
          await _register(registrar, 'unblocked-b', customer: 'customer-b')
              .timeout(const Duration(seconds: 1));
      expect(starts, ['blocked-a', 'unblocked-b']);
      expect(inventory.observed, ['unblocked-b']);
      expect(second.createdAdmissions, isEmpty);
    } finally {
      audit.release.complete();
      await first;
    }
    expect(inventory.observed, ['unblocked-b', 'blocked-a']);
  });

  test('Stop cancels in-flight and queued registrations before observation',
      () async {
    final db = _SessionDatabase();
    final starts = <String>[];
    final audit = _DiscoveryAudit(db, starts: starts, blockGroupId: 'grouping');
    final inventory = _ObservationInventory(db);
    final registrar =
        MediaMessageRegistrar(db, audit: audit, inventory: inventory);
    var active = true;
    void checkCurrent() {
      if (!active) throw StateError('automation-run-cancelled');
    }

    final first = _register(registrar, 'grouping', checkCurrent: checkCurrent);
    final firstFailure = expectLater(first, throwsStateError);
    await audit.entered.future;
    final second = _register(registrar, 'queued', checkCurrent: checkCurrent);
    final secondFailure = expectLater(second, throwsStateError);
    active = false;
    audit.release.complete();
    await Future.wait([firstFailure, secondFailure]);
    expect(starts, ['grouping']);
    expect(inventory.observed, isEmpty);

    // Stop does not clear the DB session. The next valid run guard can still
    // use this same owner queue after both cancelled registrations settle.
    active = true;
    final next =
        await _register(registrar, 'new-valid', checkCurrent: checkCurrent)
            .timeout(const Duration(seconds: 1));
    expect(starts, ['grouping', 'new-valid']);
    expect(inventory.observed, ['new-valid']);
    expect(next.createdAdmissions, isEmpty);
  });
}
