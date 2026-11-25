import 'customer_language.dart';

/// Fixed customer-facing text only. Never translates generated advice or IDs.
class FixedReplies {
  static const uncapturedHolding = '请稍等，我正在核对您刚发来的消息。';
  static const resend =
      '抱歉，我这边暂时没能看清您刚才发送的内容。方便您再描述一下遇到的问题，或重新发送图片、视频吗？我会继续帮您查看。';
  static const incompleteImageResend =
      '您之前发送的图片可能因网络原因未能完整加载，麻烦您重新发送一下这张图片，我收到后继续帮您查看。';
  static const incompleteMediaResend =
      '您之前发送的内容暂时未能完整读取，麻烦您重新发送一下，或用文字说明需要我协助的问题。';

  static const english = <String, String>{
    '请稍等片刻，我们正在核对您的问题。': 'Please wait a moment while we check your question.',
    '感谢您的耐心等待，我们正在为您查询。':
        'Thank you for your patience. We are checking this for you.',
    '请稍候，我们正在确认相关信息。':
        'Please hold on while we confirm the relevant information.',
    '我们正在查看您的问题，请稍等一下。':
        'We are looking into your question. Please wait a moment.',
    '请给我们一点时间核对详情。': 'Please give us a moment to check the details.',
    '感谢您的等待，我们还在核实中。':
        'Thank you for waiting. We are still checking the details.',
    '请稍等，我们正在整理答复。': 'Please wait a moment while we prepare your answer.',
    '我们正在进一步确认，请您稍候。': 'We are checking this further. Please hold on a moment.',
    '请耐心等待片刻，我们正在处理您的问题。':
        'Please bear with us for a moment while we work on your question.',
    '感谢您的耐心，我们正在查看具体情况。':
        'Thank you for your patience. We are reviewing the details.',
    '请稍等一下，我们正在为您确认。': 'Please wait a moment while we confirm this for you.',
    '我们正在核对详情，请稍候。': 'We are checking the details. Please hold on a moment.',
    '请稍等片刻，我们正在核实。': 'Please wait a moment while we verify this.',
    '感谢等待，我们正在确认准确答复。':
        'Thank you for waiting. We are checking the answer for accuracy.',
    '我们正在仔细查看，请您稍候。':
        'We are reviewing this carefully. Please hold on a moment.',
    '请稍候，我们正在核对信息。': 'Please hold on while we check the information.',
    '我们还在处理您的问题，请稍等。':
        'We are still working on your question. Please wait a moment.',
    '请给我们一点时间确认详情。': 'Please give us a moment to confirm the details.',
    '感谢您的等待，我们正在查询。': 'Thank you for waiting. We are looking into this.',
    '我们正在核实，很快回复您。': 'We are checking this and will reply shortly.',
    uncapturedHolding:
        'Please wait a moment while I check your latest message.',
    resend:
        'Sorry, I could not clearly read the content you just sent. Could you describe the problem again or resend the photo or video? I will continue checking it for you.',
    incompleteImageResend:
        'The image you sent earlier may not have loaded fully due to a network issue. Could you resend it so I can take a look?',
    incompleteMediaResend:
        'I could not fully read the content you sent earlier. Could you resend it, or describe in text what you need help with?',
    '您好，欢迎来到Grozziie客服。请问有什么可以帮您？':
        'Hello, welcome to Grozziie customer service. How can I help you?',
    '本客服账号仅处理京东店铺及京东订单。请问您的京东订单或产品需要什么帮助？':
        'This customer service account handles only our JD store and JD orders. How can I help with your JD order or product?',
    '我是京东店铺的客服人员，请问有什么可以帮您？':
        'I am a customer service representative for our JD store. How can I help you?',
    '不客气，很高兴能帮到您！': 'You are welcome. I am glad I could help!',
    '请告诉我您希望解决的具体问题，我会继续帮您排查。':
        'Please tell me the specific problem you want to solve, and I will help you troubleshoot it.',
    '好的，这款符合您刚才提到的需求。如果您愿意，我也可以继续帮您比较不同型号的功能。':
        'This model meets the requirements you mentioned. If you would like, I can also help compare the features of different models.',
    '目前资料还没有确认这项信息，暂时不要按未确认内容操作。':
        'The available information does not confirm this yet. Please do not act on unverified instructions.',
    '请告诉我您目前需要解决的具体问题，我会继续为您核对。':
        'Please tell me the specific problem you need to solve, and I will continue checking it for you.',
    '我理解您希望由客服同事协助。请问您遇到了什么问题？我可以先帮您处理。':
        'I understand that you would like assistance from a customer service colleague. What problem are you experiencing? I can help you with it first.',
    '我已记录您需要进一步协助，相关信息已保留，下一位有空的客服同事可以直接从这里继续处理。':
        'I have noted that you need further assistance and kept the relevant details. The next available customer service colleague can continue from here.',
    '我已记录您的退款申请，请准备好订单信息，我们会尽快核对处理。':
        'I have noted your refund request. Please have your order details ready so we can check and process it as soon as possible.',
    '很抱歉之前的步骤没有解决问题。我已保留您提供的信息和已完成的排查，后续会从这里继续，不需要您重复说明。':
        'I am sorry the previous steps did not resolve the problem. I have kept the details and troubleshooting steps already completed, so we can continue from here without asking you to repeat them.',
    '这个问题还需要进一步准确核对。我已保留您提供的详细信息，完成下一步核对后会从这里继续。':
        'This issue needs further checking. I have kept the details you provided and will continue here after the next check.',
    '这个问题还需要进一步准确核对。我已保留现有信息，完成下一步核对后会从这里继续。':
        'This issue needs more time to verify. I have kept the existing details and will continue here after the next check.',
    '我已记录您需要产品图片，我们会核对合适的图片并尽快在这里继续回复。您也可以先告诉我想了解的具体型号或功能。':
        'I have noted your request for product photos. We will check for suitable photos and follow up here as soon as possible. You can also tell me which model or features you want to know about.',
    '这个问题还需要进一步准确核对。我已保留您提供的信息，完成下一步核对后会从这里继续。':
        'This issue needs further checking. I have kept the information you provided and will continue here after the next check.',
  };

  static String choose(
          CustomerLanguage language, String chinese, String english) =>
      switch (language) {
        CustomerLanguage.chinese => chinese,
        CustomerLanguage.english => english,
        CustomerLanguage.unknown => chinese,
      };

  static String text(String chinese, CustomerLanguage language) {
    final translated = english[chinese];
    if (translated == null) throw ArgumentError('Unregistered fixed reply');
    return choose(language, chinese, translated);
  }

  static String _normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  static final _chineseByVariant = <String, String>{
    for (final entry in english.entries) ...{
      _normalize(entry.key): entry.key,
      _normalize(entry.value): entry.key,
    },
  };

  static bool isVariant(String chinese, Object? body) =>
      body is String && _chineseByVariant[_normalize(body)] == chinese;

  static String localizeIfFixed(String reply, CustomerLanguage language) {
    final chinese = _chineseByVariant[_normalize(reply)];
    return chinese == null ? reply : text(chinese, language);
  }
}
