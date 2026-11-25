import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/codex_reply_service.dart';
import 'package:jd_automation/capture/unread_capture_recovery.dart';
import 'package:jd_automation/capture/response_timing_policy.dart';

void main() {
  final now = DateTime.utc(2026, 10, 31, 10);
  Map<String, dynamic> incoming(String id, String body, int age,
          {bool image = false}) =>
      {
        'id': id,
        'direction': 'incoming',
        'body': body,
        'sent_at': now.subtract(Duration(seconds: age)).toIso8601String(),
        if (image)
          'media': [
            {'type': 'image', 'path': 'buyer-photo.jpg'}
          ],
      };
  final photo = incoming(
      'photo', '[Customer sent an image; original copied from JD cache]', 0,
      image: true);
  final question =
      incoming('question', 'what you saw in the picture i have shared?', 180);
  for (final text in [
    'what you saw in the picture i have shared?',
    'which is inside the picture?',
    'what is inside the picture?',
    '这张图片里是什么？',
    'What does this picture show?'
  ]) {
    test('recognizes observed buyer visual question: $text', () {
      expect(asksForMediaDescription(text), isTrue);
    });
  }
  test(
      'late keyboard photo carries question through missing-photo and resend exchanges',
      () {
    final history = [
      incoming('old', 'paper got stuck while printing?', 260),
      question,
      {
        'id': 'answer',
        'direction': 'outgoing',
        'body': 'The photo has not arrived. Please resend.'
      },
      incoming('resend', 'i sent it again.', 80),
      incoming('followup', 'dont YOU get it?', 60),
      photo,
    ];
    expect(
        resolveAttachedMediaQuestion(
            history: history, currentTurn: [photo], now: now),
        question['body']);
  });
  test('new troubleshooting topic ends older visual-question context', () {
    final history = [
      question,
      incoming('new-topic', 'How do I install the driver?', 40),
      photo
    ];
    expect(
        resolveAttachedMediaQuestion(
            history: history, currentTurn: [photo], now: now),
        isNull);
  });
  test('new caption has priority over an older image-description request', () {
    final caption = incoming('caption', 'Help me connect WiFi', 0);
    expect(
        resolveAttachedMediaQuestion(
            history: [question, photo, caption],
            currentTurn: [photo, caption],
            now: now),
        isNull);
  });
  test('expired request cannot control a new attachment', () {
    final old = incoming('old', 'what is inside the picture?', 301);
    expect(
        resolveAttachedMediaQuestion(
            history: [old, photo], currentTurn: [photo], now: now),
        isNull);
  });
  test('a new visual question supersedes the older one', () {
    final latest = incoming('latest', 'What does this video show?', 0);
    expect(
        resolveAttachedMediaQuestion(
            history: [question, photo, latest],
            currentTurn: [photo, latest],
            now: now),
        latest['body']);
  });
  test('fresh media recovery permits exactly two read-row recaptures', () {
    final r = UnreadCaptureRecovery(
        customer: 'customer',
        unreadEvidence: 1,
        detectedAt: now,
        knownIncomingIds: {},
        knownOutgoingIds: {});
    bool eligible() => ResponseTimingPolicy.shouldOpenForCapture(
        unread: false,
        handled: false,
        processing: true,
        retryDue: false,
        hasRecovery: true,
        verifiedMediaRecapture: r.mediaRecapturePending);
    expect(eligible(), isFalse);
    for (var attempt = 0; attempt < 2; attempt++) {
      expect(r.requestMediaRecapture(), isTrue);
      expect(eligible(), isTrue);
      expect(r.claimMediaRecapture(), isTrue);
      expect(eligible(), isFalse);
    }
    expect(r.requestMediaRecapture(), isFalse);
    expect(eligible(), isFalse);
  });
}
