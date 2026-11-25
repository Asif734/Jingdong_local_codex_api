import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/codex/customer_language.dart';
import 'package:jd_automation/codex/fixed_replies.dart';
import 'package:jd_automation/capture/response_timing_policy.dart';
import 'package:jd_automation/domain/capture_models.dart';
import 'package:jd_automation/domain/incomplete_image_policy.dart';
import 'package:jd_automation/domain/reply_progress.dart';

void main() {
  final sent = DateTime.utc(2026, 11, 12, 2, 46, 51);

  test('no action before three minutes even if the customer continued chatting',
      () {
    expect(
        IncompleteImagePolicy.decide(
            now: sent.add(const Duration(minutes: 2, seconds: 59)),
            waitingSince: sent,
            imageSentAt: sent,
            latestIncomingAt: sent.add(const Duration(seconds: 10))),
        IncompleteImageAction.wait);
  });

  test('at the deadline ask for a resend if the image is still the last input',
      () {
    for (final latest in <DateTime?>[
      null,
      sent,
      sent.subtract(Duration.zero)
    ]) {
      expect(
          IncompleteImagePolicy.decide(
              now: sent.add(const Duration(minutes: 3)),
              waitingSince: sent,
              imageSentAt: sent,
              latestIncomingAt: latest),
          IncompleteImageAction.requestResend);
    }
  });

  test('newer customer input skips the old image instead of interrupting chat',
      () {
    expect(
        IncompleteImagePolicy.decide(
            now: sent.add(const Duration(minutes: 3)),
            waitingSince: sent,
            imageSentAt: sent,
            latestIncomingAt: sent.add(const Duration(seconds: 1))),
        IncompleteImageAction.skip);
  });

  test('input during a delayed first capture still counts as continued chat',
      () {
    final firstObserved = sent.add(const Duration(seconds: 20));
    expect(
        IncompleteImagePolicy.decide(
            now: firstObserved.add(const Duration(minutes: 3)),
            waitingSince: firstObserved,
            imageSentAt: sent,
            latestIncomingAt: sent.add(const Duration(seconds: 10))),
        IncompleteImageAction.skip);
  });

  test('reread of the same sender second and older backfill are not new input',
      () {
    for (final latest in [
      sent,
      sent.add(const Duration(milliseconds: 999)),
      sent.subtract(const Duration(minutes: 10))
    ]) {
      expect(
          IncompleteImagePolicy.decide(
              now: sent.add(const Duration(minutes: 5)),
              waitingSince: sent,
              imageSentAt: sent,
              latestIncomingAt: latest),
          IncompleteImageAction.requestResend);
    }
  });

  for (final body in [
    '刚才那张图片你看到了吗？',
    '我之前发的截图怎么看？',
    '那张图里的订单有问题',
    '这个图片怎么处理',
    '图片你帮我看一下',
    '你收到图片了吗',
    '我发给你的照片上面有错误',
    'Did you see the photo I sent earlier?',
    'What about that screenshot?',
    'The issue is in the image I uploaded.',
    'Have you checked my picture?',
    'Look at the picture I sent at 10:46:51.',
    'As shown in my previous photo, it is blank.',
    'How about the picture?',
  ]) {
    test('explicit previous-image reference: $body', () {
      expect(IncompleteImagePolicy.referencesPreviousImage(body), isTrue);
    });
  }

  for (final body in [
    '',
    'hello',
    'ok',
    'Do you have ribbon change video?',
    'Send me a picture of the printer.',
    'Can you provide product photos?',
    'I want to buy photo paper.',
    'The video will not play.',
    'I will send a new photo.',
    'I will resend the image I sent earlier.',
    'I have sent another photo.',
    'Can you send me that picture?',
    'Can you send that picture to me?',
    '给我发张产品图片',
    '有没有安装图片教程',
    '有没有这个打印机的图片',
    '发送给我那张图片',
    '打印照片不清晰',
    '照片打印纸多少钱',
    '我现在发一张新图片给你',
    '我刚又发了一张图片',
    '刚才的视频没有加载',
    '[Customer sent an image; visible portion captured]',
  ]) {
    test('unrelated input does not revive a skipped image: $body', () {
      expect(IncompleteImagePolicy.referencesPreviousImage(body), isFalse);
    });
  }

  test('resend wording is fully localized and remains a useful clarification',
      () {
    final chinese = FixedReplies.text(
        FixedReplies.incompleteImageResend, CustomerLanguage.chinese);
    final english = FixedReplies.text(
        FixedReplies.incompleteImageResend, CustomerLanguage.english);
    expect(chinese, contains('可能因网络原因'));
    expect(chinese, contains('重新发送'));
    expect(english, contains('may not have loaded fully'));
    expect(english, contains('resend'));
    expect(english, isNot(matches(RegExp(r'[\u3400-\u9fff]'))));
    for (final text in [chinese, english]) {
      expect(isOnlyReplyProgressNotice(text), isFalse);
      expect(isOnlyMediaProgressNotice(text), isFalse);
      expect(ResponseTimingPolicy.isTrivialAcknowledgement(text), isFalse);
      final draft = normalizeReplyProgress(AiDraft.fromJson({
        'reply': text,
        'reply_purpose': 'media_status',
        'decision': 'draft',
        'confidence': 1,
        'risk_level': 'low',
        'model': 'incomplete-image-policy',
      }, mediaBaseUrl: Uri()));
      expect(replyPurpose(draft), ReplyPurpose.substantive);
      expect(FixedReplies.isVariant(FixedReplies.incompleteImageResend, text),
          isTrue);
    }
    expect(
        FixedReplies.text(
            FixedReplies.incompleteImageResend, CustomerLanguage.unknown),
        chinese);
  });

  for (final text in [
    '刚才图片看到了吗',
    '请帮我看看之前发的图片',
    '这个图片能看清吗？',
    'Can you check the image I sent?',
    'Did you see my photo?',
    'What about that screenshot?',
    'Look at the picture I sent at 10:46:51.',
  ]) {
    test('simple old-image clarification may use fixed resend: $text', () {
      expect(IncompleteImagePolicy.isSimpleReference(text), isTrue);
    });
  }
  for (final text in [
    '看看刚才图片，另外保修多久？',
    'Did you see the photo? Also, how long is the warranty?',
    '看看之前的图片，运费多少钱？',
    'What about that picture? Which model should I buy?',
    'Did you see my photo and is it compatible with a Mac?',
    'Can you send me that picture?',
    'I have sent another photo.',
    '刚才那张图片的二维码是什么格式？',
  ]) {
    test('mixed or uncertain question retains its full answer path: $text', () {
      expect(IncompleteImagePolicy.isSimpleReference(text), isFalse);
    });
  }
}
