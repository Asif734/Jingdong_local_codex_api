import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/viewport_evidence.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/storage/capture_database.dart';
import 'package:jd_automation/storage/capture_evidence_store.dart';
import 'package:jd_automation/storage/media_capture_audit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CaptureDatabase db;
  final at = DateTime.utc(2026, 11, 3, 2, 40, 5);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jd_pending_media_');
    db = CaptureDatabase(storageRoot: root);
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });
  Future<ViewportEvidence> frame(String id, DateTime time) async {
    final png = File('${root.path}/$id.png');
    final manifest = File('${root.path}/$id.json');
    await png.writeAsBytes([1]);
    final evidence = ViewportEvidence({
      'evidenceId': id,
      'customer': 'buyer',
      'capturedAtMs': time.millisecondsSinceEpoch,
      'imagePath': png.path,
      'manifestPath': manifest.path
    });
    await manifest.writeAsString(evidence.toJson());
    return evidence;
  }

  CapturedConversation video(String customer, DateTime clock) =>
      CapturedConversation(
          stableKey: customer,
          customerName: customer,
          customerExternalId: customer,
          capturedAt: clock,
          messages: [
            CapturedMessage(
                stableId: 'original',
                direction: 'incoming',
                body: '[Customer sent a video]',
                sentAt: clock,
                axPath: 'fixture',
                media: [
                  CapturedMedia(type: 'video', path: 'original.mp4'),
                  CapturedMedia(
                      type: 'image',
                      path: 'frame.jpg',
                      captureSource: 'jd_video_frame_1fps')
                ])
          ]);
  test(
      'loading card survives restart; ready newer frame overtakes background retry; exact original resolves task',
      () async {
    var now = at;
    var inbox = CaptureEvidenceStore(db, now: () => now);
    var audit = MediaCaptureAudit(db);
    final a = await frame('loading', at);
    await inbox.record(a);
    expect((await inbox.claim())!.id, 'loading');
    final id = await audit.discover(
        a,
        const OcrVisualRegion(
            x: .28, y: .4, width: .12, height: .28, confidence: 1));
    await audit.finish(id, 'unverified',
        {'kind': 'video', 'senderClock': at.toIso8601String()});
    await inbox.complete(a, partial: true);
    expect(await inbox.retryMedia('loading', background: true), isTrue);
    final b = await frame('ready', at.add(const Duration(seconds: 1)));
    await inbox.record(b);
    now = at.add(const Duration(seconds: 2));
    expect((await inbox.claim())!.id, 'ready');
    await inbox.complete(b);
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    audit = MediaCaptureAudit(db);
    expect(await audit.pendingForCustomer('buyer', before: now), hasLength(1));
    expect(await audit.pendingForCustomer('other', before: now), isEmpty);
    await audit.resolveCaptured(video('other', at));
    await audit
        .resolveCaptured(video('buyer', at.add(const Duration(seconds: 1))));
    expect(await audit.pendingForCustomer('buyer', before: now), hasLength(1));
    await db.saveCapture(video('buyer', at));
    await audit.resolveCaptured(video('buyer', at));
    expect(await audit.pendingForCustomer('buyer', before: now), isEmpty);
    await audit
        .finish(id, 'unverified', {'reason': 'old_loading_frame_rechecked'});
    expect(await audit.pendingForCustomer('buyer', before: now), isEmpty);
  });
  test(
      'platform rejected OCR bubble cannot answer or remove the pending customer',
      () async {
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        capturedAt: at,
        messages: [
          CapturedMessage(
              stableId: 'question',
              direction: 'incoming',
              body: 'Did you get my video?',
              sentAt: at,
              axPath: 'fixture')
        ]));
    await db.saveCapture(CapturedConversation(
        stableKey: 'buyer',
        customerName: 'buyer',
        capturedAt: at.add(const Duration(seconds: 10)),
        messages: [
          CapturedMessage(
              stableId: 'failed-bubble',
              direction: 'outgoing',
              body: 'Yes, I received your video. 该顾客正在咨询其他客服，无法回复顾客消息',
              sentAt: at.add(const Duration(seconds: 10)),
              axPath: 'fixture')
        ]));
    expect(await db.hasPendingUnanswered('buyer'), isTrue);
  });
}
