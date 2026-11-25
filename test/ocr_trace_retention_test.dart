import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';

void main() {
  test(
      'OCR trace is not recovered as a second evidence manifest and is pruned with its frame',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_ocr_trace_');
    final db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final cache = await Directory('${root.path}/capture_evidence').create();
    final image = File('${cache.path}/frame.png');
    await image.writeAsBytes([1]);
    final manifest = File('${cache.path}/frame.json');
    final frame = ViewportEvidence({
      'evidenceId': 'frame',
      'customer': 'buyer',
      'imagePath': image.path,
      'manifestPath': manifest.path,
      'capturedAtMs': DateTime.now().millisecondsSinceEpoch,
      'windowBounds': {'width': 1440, 'height': 813}
    });
    await manifest.writeAsString(frame.toJson());
    final sidecar = File('${manifest.path}.ocr.json');
    await sidecar.writeAsString(jsonEncode(
        {'evidenceId': 'frame', 'customer': 'buyer', 'observations': []}));
    final store = CaptureEvidenceStore(db);
    await store.record(frame);
    // Simulate an interrupted/moved original manifest. A diagnostic-only file
    // must not take over the immutable screenshot's metadata during recovery.
    final moved = await manifest.rename('${manifest.path}.bak');
    await store.recover(cache);
    final recovered = await store.lookup('frame');
    expect(recovered!.manifestPath, manifest.path);
    expect(recovered.metadata['windowBounds'], {'width': 1440, 'height': 813});
    await moved.rename(manifest.path);
    await store.complete(frame);
    await store.pruneProcessed(keep: 0);
    expect(await sidecar.exists(), isFalse);
    expect(await image.exists(), isFalse);
    expect(await manifest.exists(), isFalse);
  });
}
