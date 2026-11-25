import '../capture/transcript_text.dart';

/// Only actual customer text establishes language. Attachments and model names
/// inherit history; seller replies and transfer notices never establish it.
enum CustomerLanguage {
  chinese('zh'),
  english('en'),
  unknown('und');

  const CustomerLanguage(this.code);
  final String code;
  String get replyCode => this == unknown ? chinese.code : code;
}

class CustomerLanguageChoice {
  const CustomerLanguageChoice(this.language, this.sourceMessageId);
  final CustomerLanguage language;
  final String? sourceMessageId;
}

/// JD Automation uses one outbound language, independently of customer input.
class ChineseOnlyReplyPolicy {
  static const language = CustomerLanguage.chinese;
  static const instruction =
      'Write every customer-facing sentence in Simplified Chinese, even when '
      'the customer writes in English or asks for another language. Keep '
      'model numbers, product names, necessary UI labels and URLs as written.';
  static final _han = RegExp(r'[\u3400-\u9fff]');
  static bool accepts(String text) => _han.hasMatch(text);
}

class CustomerLanguageResolver {
  static final _han = RegExp(r'[\u3400-\u9fff]');
  static final _ack = RegExp(r'^(?:ok(?:ay)?|k|yes|no|yep|nope)[.!?\s]*$',
      caseSensitive: false);

  static CustomerLanguageChoice resolve(
      Iterable<Map<String, dynamic>> messages) {
    CustomerLanguageChoice? latest;
    DateTime? latestAt;
    CustomerLanguageChoice? undatedHistoryFallback;
    for (final message in messages.toList().reversed) {
      if (message['direction'] != 'incoming' ||
          message['source'] == 'transfer_notice' ||
          const {
            'image_ocr',
            'video_subtitle',
            'video_transcript',
            'audio_transcript',
            'media_analysis'
          }.contains(message['source']) ||
          const {
            'media',
            'image_ocr',
            'video_subtitle',
            'video_speech',
            'media_analysis'
          }.contains(message['text_origin']) ||
          (message['text_origin'] != 'customer_text' &&
              (message['media'] as List? ?? const []).isNotEmpty)) {
        continue;
      }
      final language = fromText(message['body']?.toString() ?? '');
      if (language == null) continue;
      final senderAt = DateTime.tryParse(message['sent_at']?.toString() ?? '');
      if (message['capture_purpose'] == 'history_only' && senderAt == null) {
        // Observation time dates the backfill, not the customer's utterance.
        // Such history may provide a fallback for a first image-only turn,
        // but cannot override current text or a dated language preference.
        undatedHistoryFallback ??=
            CustomerLanguageChoice(language, message['id']?.toString());
        continue;
      }
      final at = senderAt ??
          DateTime.tryParse(message['captured_at']?.toString() ?? '');
      // A late OCR backfill of an older bubble must not reverse a newer
      // language switch. Preserve history order for equal/unknown clocks.
      if (latest == null ||
          (at != null && latestAt != null && at.isAfter(latestAt))) {
        latest = CustomerLanguageChoice(language, message['id']?.toString());
        latestAt = at;
      }
    }
    return latest ??
        undatedHistoryFallback ??
        const CustomerLanguageChoice(CustomerLanguage.unknown, null);
  }

  static CustomerLanguage? fromText(String body) {
    var text = TranscriptText.clean(body);
    if (text.isEmpty ||
        RegExp(r'^\[(?:Customer sent|image|video|图片|视频)', caseSensitive: false)
            .hasMatch(text) ||
        RegExp(r'将客户.*转接给您|转给子账号|上次会话小结.*用户诉求').hasMatch(text)) {
      return null;
    }
    final shortPreference = RegExp(
      r'^(?:please\s+)?use\s+(English|Chinese)(?:\s+please)?[.!?\s]*$|^(?:请|麻烦)?(?:用|使用|改用|换成)?(中文|汉语|英文|英语)(?:回复|回答|交流)?(?:[,，]?谢谢)?[。！\s]*$',
      caseSensitive: false,
    ).firstMatch(text);
    if (shortPreference != null) {
      final name = shortPreference.group(1) ?? shortPreference.group(2)!;
      return RegExp(r'English|英文|英语', caseSensitive: false).hasMatch(name)
          ? CustomerLanguage.english
          : CustomerLanguage.chinese;
    }
    final explicit = RegExp(
      r'(?:用|使用|改用|换成)(中文|汉语|英文|英语)(?:来)?(?:回复|回答|说|交流|解释)|(?:reply|answer|respond|speak|continue|write|explain)\s+(?:to me\s+)?(?:in\s+)?(English|Chinese)|^(English|Chinese|中文|英文|英语|汉语)(?:\s+please)?[.!?。！\s]*$',
      caseSensitive: false,
    ).allMatches(text).lastOrNull;
    if (explicit != null) {
      final name = explicit.group(1) ?? explicit.group(2) ?? explicit.group(3)!;
      return RegExp(r'英文|英语|english', caseSensitive: false).hasMatch(name)
          ? CustomerLanguage.english
          : CustomerLanguage.chinese;
    }
    if (_ack.hasMatch(text)) return null;
    text = text
        .replaceAll(RegExp(r'https?://\S+|\b\S+@\S+\b'), ' ')
        .replaceAll(
            RegExp(
                r'\b(?:[A-Za-z]+[-_ ]?\d[A-Za-z0-9._/-]*|\d+(?:\.\d+)?(?:mm|cm|dpi|px|ghz|gb|mb))\b',
                caseSensitive: false),
            ' ')
        .replaceAll(
            RegExp(
                r'\b(?:Grozziie|JD|USB|Wi-Fi|wifi|bluetooth|Android|iOS|Windows|macOS)\b',
                caseSensitive: false),
            ' ');
    text = text.replaceAll(RegExp(r'格志打印(?:机|料)?|格志|速印通'), ' ');
    final hanCount = _han.allMatches(text).length;
    final words = RegExp(r'[a-zA-Z]{2,}').allMatches(text).toList();
    final englishChars =
        words.fold<int>(0, (sum, word) => sum + word.group(0)!.length);
    if (hanCount > 0) {
      return words.length >= 2 && englishChars > hanCount * 2
          ? CustomerLanguage.english
          : CustomerLanguage.chinese;
    }
    return words.isEmpty ? null : CustomerLanguage.english;
  }

  static String instruction(CustomerLanguage language) => switch (language) {
        CustomerLanguage.chinese =>
          'Choose language ONLY from customer-authored chat text; never from image text, video subtitles, audio transcripts or media analysis. Reply entirely in Chinese, including greetings, clarifications, safety notices and fallback wording. Preserve product model names and URLs.',
        CustomerLanguage.english =>
          'Choose language ONLY from customer-authored chat text; never from image text, video subtitles, audio transcripts or media analysis. Reply entirely in English, including greetings, clarifications, safety notices and fallback wording. Translate knowledge written in Chinese; never copy Chinese answer text. Preserve product model names and URLs.',
        CustomerLanguage.unknown =>
          'No customer language has been established. Default to Chinese until meaningful customer text establishes a language. Do not infer language from images, video, model names, seller text or system notices.',
      };
}
