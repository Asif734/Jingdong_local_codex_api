import 'dart:math';

import 'customer_language.dart';
import 'fixed_replies.dart';

const chineseHoldingReplies = <String>[
  '请稍等片刻，我们正在核对您的问题。',
  '感谢您的耐心等待，我们正在为您查询。',
  '请稍候，我们正在确认相关信息。',
  '我们正在查看您的问题，请稍等一下。',
  '请给我们一点时间核对详情。',
  '感谢您的等待，我们还在核实中。',
  '请稍等，我们正在整理答复。',
  '我们正在进一步确认，请您稍候。',
  '请耐心等待片刻，我们正在处理您的问题。',
  '感谢您的耐心，我们正在查看具体情况。',
  '请稍等一下，我们正在为您确认。',
  '我们正在核对详情，请稍候。',
  '请稍等片刻，我们正在核实。',
  '感谢等待，我们正在确认准确答复。',
  '我们正在仔细查看，请您稍候。',
  '请稍候，我们正在核对信息。',
  '我们还在处理您的问题，请稍等。',
  '请给我们一点时间确认详情。',
  '感谢您的等待，我们正在查询。',
  '我们正在核实，很快回复您。',
];

final englishHoldingReplies = chineseHoldingReplies
    .map((reply) => FixedReplies.text(reply, CustomerLanguage.english))
    .toList(growable: false);

String chooseHoldingReply(String latestCustomerText,
    {Random? random, CustomerLanguage? language}) {
  final selected = chineseHoldingReplies[
      (random ?? Random()).nextInt(chineseHoldingReplies.length)];
  return FixedReplies.text(
      selected,
      language ??
          CustomerLanguageResolver.fromText(latestCustomerText) ??
          CustomerLanguage.chinese);
}

bool isHoldingReply(Object? body) =>
    FixedReplies.isVariant(FixedReplies.uncapturedHolding, body) ||
    chineseHoldingReplies.any((reply) => FixedReplies.isVariant(reply, body));

bool isRecoveryReply(Object? body) =>
    isHoldingReply(body) || FixedReplies.isVariant(FixedReplies.resend, body);

final _holdingPatterns = [
  for (final reply in {
    ...chineseHoldingReplies,
    ...englishHoldingReplies,
    FixedReplies.uncapturedHolding,
    FixedReplies.text(FixedReplies.uncapturedHolding, CustomerLanguage.english),
  })
    RegExp(reply.split(RegExp(r'\s+')).map(RegExp.escape).join(r'\s*'),
        caseSensitive: false),
];

String stripAppendedHoldingReply(String body) {
  var end = body.length;
  for (final pattern in _holdingPatterns) {
    for (final match in pattern.allMatches(body)) {
      if (match.start < end &&
          !_isQuoted(body, match.start, match.end - match.start)) {
        end = match.start;
      }
    }
  }
  return body.substring(0, end).trim();
}

bool _isQuoted(String body, int start, int length) {
  for (final pair in [('“', '”'), ('「', '」'), ('"', '"'), ("'", "'")]) {
    final before = <int>[];
    final after = <int>[];
    for (var index = 0; index < body.length; index++) {
      if (body[index] != pair.$1 && body[index] != pair.$2) continue;
      // Apostrophes inside English words are not quotation marks.
      if (pair.$1 == "'" &&
          index > 0 &&
          index + 1 < body.length &&
          RegExp(r'[A-Za-z]').hasMatch(body[index - 1]) &&
          RegExp(r'[A-Za-z]').hasMatch(body[index + 1])) {
        continue;
      }
      if (index < start) before.add(index);
      if (index >= start + length) after.add(index);
    }
    if (pair.$1 == pair.$2) {
      if (before.length.isOdd && after.isNotEmpty) return true;
    } else if (before.isNotEmpty &&
        body[before.last] == pair.$1 &&
        after.isNotEmpty &&
        body[after.first] == pair.$2) {
      return true;
    }
  }
  return false;
}
