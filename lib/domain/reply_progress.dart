import 'dart:convert';

import 'capture_models.dart';

enum ReplyPurpose { substantive, mediaStatus, receipt, reviewStatus }

ReplyPurpose replyPurpose(AiDraft draft) {
  final raw = jsonDecode(draft.rawJson) as Map;
  return switch (raw['reply_purpose']) {
    'media_status' => ReplyPurpose.mediaStatus,
    'receipt' => ReplyPurpose.receipt,
    'review_status' => ReplyPurpose.reviewStatus,
    _ => ReplyPurpose.substantive,
  };
}

/// A model purpose is not proof that an actual answer is only a notice. In
/// particular, a useful answer must survive an accidentally retained review
/// label. Check the whole text against the deliberately small notice grammar.
bool isReviewAcknowledgement(Map raw) =>
    !(raw['automatic_progress_classified'] == true &&
        raw['reply_purpose'] == 'receipt') &&
    isOnlyReplyProgressNotice(raw['reply']?.toString() ?? '') &&
    (raw['reply_purpose'] == 'review_status' ||
        raw['review_acknowledgement_only'] == true ||
        (raw['human_review_required'] == true &&
            raw['decision'] == 'human_review_required' &&
            (raw['risk_triggers'] as List? ?? const [])
                .contains('solution_not_found') &&
            raw['reason'] == 'Codex could not find a reliable solution.'));

/// This recognizes only complete waiting/handling promises, not answer
/// quality. Any unfamiliar clause, concrete fact, step, or useful question
/// keeps the real response on its existing answer path.
bool isOnlyReplyProgressNotice(String reply) {
  final text = reply.trim();
  if (text.isEmpty) return false;
  final clauses = text
      .split(RegExp(r'[，,。.!！?？;；\n]+'))
      .map((clause) => clause.trim().replaceFirst(
          RegExp(r'^(?:(?:and|but|also)\s+|但是|不过|但)', caseSensitive: false),
          ''))
      .where((clause) => clause.isNotEmpty)
      .toList();
  if (clauses.isEmpty) return false;
  return clauses.any((clause) => !_replyNoticeNeutral.hasMatch(clause)) &&
      clauses.every((clause) =>
          _replyNoticeClauses.any((pattern) => pattern.hasMatch(clause)));
}

// Greetings and thanks may prefix a notice, but are complete social replies
// in their own right; they do not promise that an answer is still pending.
final _replyNoticeNeutral = RegExp(
    r'^(?:(?:您好|你好|亲|好的|好|收到|已收到|明白了|了解了|谢谢|感谢您的理解)|(?:谢谢|感谢)(?:您|您的)?(?:耐心)?(?:等待|理解|配合)|hello|hi|okay|ok|understood|noted|received|thank you|thanks|(?:thank you|thanks)(?:\s+for)?\s+(?:your patience|waiting|your understanding))$',
    caseSensitive: false);

final _replyNoticeClauses = <RegExp>[
  for (final pattern in [
    r'(?:您好|你好|亲|好的|好|收到|已收到|明白了|了解了|谢谢|感谢您的理解)',
    r'(?:请|请您|麻烦您|麻烦)?(?:稍等|稍候|稍后|等待|耐心等待)(?:一下|片刻|一会儿?|一小会儿?|一点时间|几分钟|[0-9]+\s*(?:秒|分钟))?(?:哦|哈|呀|呢)?',
    r'(?:请|请您)?给(?:我|我们)(?:一)?点时间(?:核对|确认|核实|查看|查询|处理)(?:详情|信息|情况)?',
    r'(?:谢谢|感谢)(?:您|您的)?(?:耐心)?(?:等待|理解|配合)',
    r'(?:我|我们)?(?:正在|还在|仍在|目前正在|会|将)?(?:为您|帮您|替您)?(?:进一步|仔细)?(?:核对|确认|核实|查看|查询|检查|整理|处理|研究|分析)(?:您|您的|您提供的|相关|具体|准确|现有|详细|这个|一下|一下您的|一下相关)?(?:问题|信息|情况|详情|答复|回复|结果|内容|资料)?(?:中)?',
    r'(?:我|我们)?(?:会|将|可以|正在)?(?:在这里|继续|进一步)?(?:为您|帮您|协助您|帮助您)(?:处理|查询|查看|核对|解决)?(?:您|您的|这个|相关)?(?:问题|情况|信息)?',
    r'(?:这个问题|相关信息|具体情况|详细情况|订单信息)(?:还|仍)?需要(?:进一步|准确|仔细)*(?:核对|确认|核实|查询|处理)',
    r'(?:我|我们)?(?:已|已经)(?:记录|保留|保存)(?:了)?(?:您|您的|您提供的|相关|现有|详细)*(?:问题|信息|详情|情况|资料)(?:和已完成的排查)?',
    r'(?:相关|现有|详细)?(?:信息|问题|详情|情况|资料)(?:已|已经)(?:记录|保留|保存)',
    r'(?:完成|等|待)(?:下一步|进一步)?(?:核对|确认|核实|查询|处理)(?:完成)?后(?:我|我们)?(?:会|将)?(?:在这里|从这里)?(?:继续|回复您|答复您|继续回复您|继续处理)',
    r'(?:我|我们)?(?:会|将|正在)?(?:尽快|很快|稍后)(?:在这里)?(?:回复|答复|联系)(?:您|你)',
    r'(?:您|您的|刚才的|这条|该)?(?:视频|图片|照片|附件|媒体)(?:消息|内容|原件)?(?:已|已经)(?:收到|接收|保存)',
    r'(?:我|我们|我这边|这边)?(?:已|已经|确认|刚刚|确实)?(?:收到|看到|看到了|接收到了)(?:了)?(?:您|您的|你|你发的|刚才的|这|该|发来|发送的|的)*(?:(?:[0-9]+|[一二两三四五六七八九十]+)(?:个|段|张|条|份)?)?(?:图片|视频|照片|附件|媒体)(?:消息)?',
    r'(?:一共|总共|共有)\s*(?:[0-9]+|[一二两三四五六七八九十]+)\s*(?:个|段|张|条|份)?(?:图片|视频|照片|附件)',
    r'(?:您|您的|这条|该)?(?:视频|图片|照片|附件|媒体)(?:消息|内容|原件)?(?:仍|还|尚)?(?:在|正在|未|没|没有|尚未)?(?:完整)?(?:加载|下载|读取|获取|提取|处理|解析)(?:完成|完|好|中)?',
    r'(?:您|您的|这条|该)?(?:视频|图片|照片|附件|媒体)(?:的)?(?:内容|原件)?(?:仍|还|尚)?(?:未就绪|不可用|无法读取|未完整提取|未完整加载|没有完整提取|没有完整加载)',
    r'(?:我|我们)?(?:正在|会|将)?(?:帮您|为您)?(?:转接|转交|联系)(?:有空的|下一位有空的|相关|其他|另一位)?(?:客服|客服同事|同事)(?:处理|协助|继续处理)?',
    r'(?:下一位有空的|有空的|相关|其他|另一位)?(?:客服同事|客服|同事)(?:会|可以)?(?:直接)?(?:在这里|从这里)?(?:继续|继续处理|协助您|帮助您)',
    r'(?:hello|hi|okay|ok|understood|noted|received|thank you|thanks)',
    r'(?:please\s+)?(?:wait|hold on|bear with (?:me|us))(?:\s+(?:a moment|a little longer|briefly|for a moment|for (?:a few|[0-9]+) (?:seconds|minutes)))?',
    r'(?:one|just a|a)\s+moment(?:\s+please)?',
    r'(?:thank you|thanks)(?:\s+for)?\s+(?:your patience|waiting|your understanding)',
    r'(?:i|we)(?:\s+(?:am|are)|[’\x27](?:m|re))?\s+(?:still\s+|currently\s+)?(?:checking|reviewing|verifying|looking into|working on|processing|preparing|retrieving|loading)\s*(?:(?:the|your|this|that|relevant|available|existing|provided|detailed|specific|accurate)\s+)*(?:issue|question|details|information|reply|response|content|case|request)?',
    r'(?:please\s+)?(?:wait|hold on)(?:\s+a moment)?\s+while\s+(?:i|we)\s+(?:check|review|verify|look into)(?:\s+(?:(?:the|your|this|relevant)\s+)*(?:issue|question|details|information|case|request))?',
    r'(?:please\s+)?wait(?:\s+(?:a moment|briefly|a little longer))?\s+while\s+(?:i|we)\s+(?:request assistance from|contact|connect you to)\s+(?:my|a|our|the)\s+(?:customer service\s+)?colleague(?:\s+[A-Za-z\u4e00-\u9fff][A-Za-z\u4e00-\u9fff -]{0,39})?',
    r'your\s+request\s+for\s+assistance\s+from\s+[A-Za-z\u4e00-\u9fff][A-Za-z\u4e00-\u9fff -]{0,39}\s+is\s+(?:still\s+)?being\s+(?:handled|processed|reviewed)',
    r'let me\s+(?:check|review|verify|look into)\s+(?:this|that|it)(?:\s+for you)?',
    r'(?:i|we)\s+(?:will|can)\s+(?:continue\s+)?(?:help|assist|helping|assisting)(?:\s+you)?(?:\s+(?:here|with (?:this|your) (?:issue|question|request)))?',
    r'(?:i|we)\s+(?:will|can)\s+(?:check|review|verify|look into)\s+(?:(?:the|your|this|relevant)\s+)*(?:issue|question|details|information|case|request)',
    r'(?:i|we)\s+(?:will|shall)\s+(?:reply|respond|get back to you)(?:\s+(?:here|soon|shortly|as soon as possible))?',
    r'(?:i|we)\s+(?:have\s+)?(?:saved|recorded|kept|retained)\s+(?:(?:the|your|this|relevant|existing|provided|detailed)\s+)*(?:details|information|issue|question|request)(?:\s+(?:you provided|for (?:checking|review|verification)))?(?:\s+and will continue here after the next check)?',
    r'(?:this|the|your)\s+(?:issue|question|request|information)\s+(?:still\s+)?(?:needs?|requires?)\s+(?:(?:further|more|accurate|careful)\s+)*(?:checking|review|verification|time to verify)',
    r'(?:i|we)\s+(?:will|can)\s+continue\s+(?:here|from here)(?:\s+after (?:checking|review|verification))?',
    r'(?:(?:the|your|this)\s+)?(?:media|attachment|video|image|photo|clip)(?:\s+(?:message|content|original|file))?\s+(?:has arrived|has been received|has been saved|is received|is saved)',
    r'(?:(?:the|your|this)\s+)?(?:media|attachment|video|image|photo|clip)(?:\s+(?:message|content|original|file))?\s+is\s+(?:still\s+)?(?:loading|downloading|being (?:processed|retrieved|loaded|downloaded)|not (?:yet )?(?:ready|available|readable)|unavailable)',
    r'(?:i|we)(?:\s+have|[’\x27]ve)?\s+(?:received|can see|have received)\s+(?:(?:the|your|this|that|a|an|latest|new)\s+)*(?:(?:[0-9]+|one|two|three|four|five|six|seven|eight|nine|ten)\s+)?(?:media|attachment|video|image|photo|picture|clip)s?(?:\s+message)?',
    r'there\s+(?:are|is)\s+(?:[0-9]+|one|two|three|four|five|six|seven|eight|nine|ten)\s+(?:attachments?|videos?|images?|photos?|pictures?|clips?)',
    r'(?:its|the|your|this)\s+content\s+is\s+(?:still\s+)?(?:loading|not (?:yet )?(?:ready|available|readable)|being (?:processed|retrieved|loaded)|unavailable)',
    r'(?:i|we)\s+(?:will|am|are)\s+(?:transfer|transferring|connect|connecting|forward|forwarding)\s+you\s+to\s+(?:a|another|the next available|my)\s+(?:customer service\s+)?(?:colleague|agent)',
  ])
    RegExp('^(?:$pattern)\$', caseSensitive: false),
];

/// Preserve all evidence, risk, identity and intent fields. The purpose alone
/// must not discard a normal answer, and a waiting promise alone cannot close
/// the customer's work even if its model label claims otherwise.
AiDraft normalizeReplyProgress(AiDraft draft) {
  final raw = jsonDecode(draft.rawJson) as Map<String, dynamic>;
  final pureNotice = isOnlyReplyProgressNotice(draft.reply);
  if (pureNotice) {
    if ((raw['reply_purpose'] == 'receipt' &&
            isReceiptFactReply(draft.reply)) ||
        raw['reply_purpose'] == 'media_status') {
      return draft;
    }
    if (raw['reply_purpose'] == 'review_status' &&
        raw['review_acknowledgement_only'] == true) {
      return draft;
    }
    return withReplyProgress(draft, {
      'reply_purpose': 'review_status',
      'review_acknowledgement_only': true,
    });
  }
  if (raw['reply_purpose'] != 'review_status' &&
      raw['reply_purpose'] != 'media_status' &&
      raw['review_acknowledgement_only'] != true) {
    return draft;
  }
  raw
    ..['reply_purpose'] = 'substantive'
    ..remove('review_acknowledgement_only');
  return AiDraft(
    reply: draft.reply,
    decision: draft.decision,
    confidence: draft.confidence,
    riskLevel: draft.riskLevel,
    model: draft.model,
    usedRecordIds: draft.usedRecordIds,
    actions: draft.actions,
    attachments: draft.attachments,
    imageDescriptions: draft.imageDescriptions,
    ticket: draft.ticket,
    rawJson: jsonEncode(raw),
  );
}

/// A receipt question can be answered by the actual receipt/count fact even
/// when the same reply explains that analysis is still in progress. Merely
/// promising to check or asking the customer to wait proves no receipt.
bool isReceiptFactReply(String reply) {
  final text = reply.trim();
  if (RegExp(
          r'(?:正在|还在|仍在)(?:接收|获取|下载)|(?:收到|接收)(?:后|以后)|\b(?:will|may|might|could)\s+(?:receive|see)\b',
          caseSensitive: false)
      .hasMatch(text)) {
    return false;
  }
  return RegExp(
          r'(?:已|已经|确认|刚刚|确实)?(?:收到|接收到了|看到了|能看到|可以看到)(?:了)?(?:您|您的|你|你发的|刚才的|这|该|发来|发送的|的|一|两|二|三|四|五|六|七|八|九|十|[0-9]|个|段|张|条|份|\s)*(?:图片|视频|照片|附件|媒体)|(?:图片|视频|照片|附件|媒体)(?:消息|内容)?(?:已经|已|确实|刚刚)?(?:收到|接收到了|看到了)|(?:没|没有|尚未)(?:收到|看到)(?:您|您的|你|的|发来|发送的|这|该|\s)*(?:图片|视频|照片|附件|媒体)|(?:共有|一共|总共|收到|看到)(?:了)?\s*(?:[0-9]+|[一二两三四五六七八九十]+)\s*(?:个|段|张|条|份)?(?:图片|视频|照片|附件)|\b(?:i|we)(?:\s+have|[’\x27]ve)?\s+(?:received|can see|have received)\s+(?:(?:the|your|this|that|a|an|latest|new)\s+)*(?:(?:[0-9]+|one|two|three|four|five|six|seven|eight|nine|ten)\s+)?(?:media|attachment|video|image|photo|picture|clip)s?\b|\b(?:the|your|this)\s+(?:media|attachment|video|image|photo|picture|clip)(?:\s+message)?\s+(?:has arrived|has been received|was received)\b|\b(?:i|we)\s+(?:have not|haven[’\x27]t|did not|didn[’\x27]t|cannot|can[’\x27]t)\s+(?:received?|see|seen)\s+(?:(?:the|your|this|that|any)\s+)*(?:media|attachment|video|image|photo|picture|clip)s?\b|\b(?:there (?:are|is)|received|can see)\s+(?:[0-9]+|one|two|three|four|five|six|seven|eight|nine|ten)\s+(?:attachments?|videos?|images?|photos?|pictures?|clips?)\b',
          caseSensitive: false)
      .hasMatch(text);
}

/// Only the storage correction operation writes this provenance. An OCR body
/// cannot declare a real image/video to be text, including for a legacy ID
/// whose spelling starts with `media-pending:`.
bool isClarifiedTextMessage(Map message) {
  final proof = message['message_kind_evidence'];
  return message['message_kind'] == 'text' &&
      message['text_origin'] == 'customer_text' &&
      message['media_receipt_id'] == null &&
      (message['media'] as List? ?? const []).isEmpty &&
      proof is Map &&
      proof['source'] == 'proven_unknown_bubble_text' &&
      proof['parentMessageId'] == message['id'] &&
      proof['receiptId'] is String &&
      proof['observationId'] is String &&
      proof['evidenceId'] is String &&
      (message['live_observed_session_ids'] as List? ?? const [])
          .contains(proof['sessionId']);
}

bool isMediaWorkMessage(Map message) =>
    !isClarifiedTextMessage(message) &&
    (message['text_origin'] == 'media' ||
        message['media_receipt_id'] != null ||
        message['id'].toString().startsWith('media-pending:') ||
        (message['media'] as List? ?? const []).isNotEmpty);

bool isExplicitMediaReceiptQuestion(String body) {
  final text = body.trim();
  if (!RegExp(r'video|clip|image|photo|picture|attachment|media|视频|图片|照片|附件',
          caseSensitive: false)
      .hasMatch(text)) {
    return false;
  }
  if (RegExp(r'\b(?:and|also)\b|另外|还有|以及', caseSensitive: false)
      .hasMatch(text)) {
    return false;
  }
  final asksReceipt = RegExp(
          r'(?:did|have|can|do|could).{0,20}(?:get|receiv|see)|how many.{0,20}(?:sent|receiv|video|clip|image|photo|picture|attachment)|(?:收|看)到.{0,12}(?:吗|没|了)|(?:有|收到).{0,8}(?:几|多少)(?:个|段|张|条)|几(?:个|段|张|条).{0,8}(?:视频|图片|照片)|(?:视频|图片|照片).{0,8}不是发你了[吗么]',
          caseSensitive: false)
      .hasMatch(text);
  if (!asksReceipt) return false;

  // A receipt answer may cover this entire text input. Accept only receipt
  // vocabulary; any content/operation question must take the full answer path.
  // Conservatively delegating an unfamiliar phrasing to Codex loses no work.
  final english = ('did have has can could do does you i we get got receive '
          'received receiving see seen saw send sent sending how many much number '
          'count total of my the a an these those this that it them your me us '
          'video videos clip clips image images photo photos picture pictures '
          'attachment attachments media message messages first second third last '
          'latest previous earlier one two three four five six seven eight nine '
          'ten all both just already yet recently actually please hi hello kindly '
          'confirm whether if tell now not are is were was there thank thanks')
      .split(' ')
      .toSet();
  final words = RegExp(r"[a-z]+(?:['’][a-z]+)?", caseSensitive: false);
  if (words
      .allMatches(text)
      .any((word) => !english.contains(word.group(0)!.toLowerCase()))) {
    return false;
  }
  var remaining = text.replaceAll(words, '');
  remaining = remaining.replaceAll(
      RegExp(
          r'请问|您好|你好|麻烦|谢谢|刚才|刚刚|之前|上次|最新|最后|这张|那张|这些|那些|这个|那个|上一张|上一个|上一段|前一张|前一个|前一段|第[一二三四五六七八九十0-9]+|视频|图片|照片|附件|消息|发送|发给|发来|发过|发|收到了|收到|看到|看见|确认|一下|是否|能否|有没有|没有|还没|已经|到底|多少|总共|一共|数量|这里|那边|这边|现在|可以|能够|是不是|不是|你们|我们|我|你|您|亲|请|帮|给|到|在|这|那|的|了|吗|嘛|么|啊|呀|呢|没|是|不|收|看|能|有|已|还|几|两|一|个|段|张|条|份|对吧|吧'),
      '');
  return remaining
      .replaceAll(RegExp(r'[\s0-9\p{P}\p{S}]', unicode: true), '')
      .isEmpty;
}

/// Compatibility for automatic results produced without the new purpose
/// field. This accepts only a short progress notice, never an arbitrary reply
/// which happens to mention loading alongside a real answer or instruction.
bool isOnlyMediaProgressNotice(String reply) {
  final text = reply.trim();
  if (!isOnlyReplyProgressNotice(text) ||
      text.length > 300 ||
      RegExp(r'\?|？|\b(?:switch|unplug|reload|remove|connect|press|supports?|warranty|costs?|choose|select)\b|请问|支持|保修|拔掉|关闭|打开|重新装|按下|选择',
              caseSensitive: false)
          .hasMatch(text)) {
    return false;
  }
  return RegExp(r'media|attachment|video|image|photo|clip|视频|图片|附件|照片',
              caseSensitive: false)
          .hasMatch(text) &&
      RegExp(r'loading|(?:still |not yet |not )(?:available|ready|confirmed|readable)|being (?:processed|retrieved|loaded)|content.{0,25}(?:unavailable|not available)|(?:内容|视频|图片|附件).{0,20}(?:加载|读取|获取|尚未|未就绪|还没|处理中)',
              caseSensitive: false)
          .hasMatch(text);
}

AiDraft withReplyProgress(AiDraft draft, Map<String, Object?> fields) =>
    AiDraft(
      reply: draft.reply,
      decision: draft.decision,
      confidence: draft.confidence,
      riskLevel: draft.riskLevel,
      model: draft.model,
      usedRecordIds: draft.usedRecordIds,
      actions: draft.actions,
      attachments: draft.attachments,
      imageDescriptions: draft.imageDescriptions,
      ticket: draft.ticket,
      rawJson: jsonEncode({
        ...jsonDecode(draft.rawJson) as Map<String, dynamic>,
        ...fields,
      }),
    );
