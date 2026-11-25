import '../runtime/account_pinyin.dart';

/// An explicit request to contact one named service account. The caller must
/// supply the customer's actual message, never a summary containing old names.
class NamedAgentRequest {
  const NamedAgentRequest._(this.target, this.isStandalone);

  final String target;

  /// Only a transfer request and politeness, with no question left to answer.
  final bool isStandalone;

  static NamedAgentRequest? parse(String message) {
    final text = message.trim();
    if (text.isEmpty ||
        RegExp(r'或者|或是|要么|不然|要不|\beither\b|\bor\b', caseSensitive: false)
            .hasMatch(text)) {
      return null;
    }
    final targets = <String>{};
    var standalone = true;
    for (final part in text.split(RegExp(r'[，,。；;！!？?\n]+'))) {
      final clause = part.trim().replaceFirst(RegExp(r'\.+$'), '').trim();
      if (clause.isEmpty || _politeness.hasMatch(clause)) continue;
      if (_negation.hasMatch(clause)) {
        standalone = false;
        continue;
      }
      final direct = _chineseAction.firstMatch(clause) ??
          _englishAction.firstMatch(clause) ??
          _romanizedAction.firstMatch(clause);
      final assigned =
          direct == null ? _assignedReception.firstMatch(clause) : null;
      final raw = direct?.group(1) ?? assigned?.group(1);
      if (raw == null) {
        standalone = false;
        continue;
      }
      final parsed = _target(raw);
      if (parsed == null) return null;
      targets.add(parsed.$1);
      standalone = standalone && parsed.$2;
      if (assigned != null && !_onlyPoliteness(assigned.group(2) ?? '')) {
        standalone = false;
      }
    }
    if (targets.length != 1) return null;
    return NamedAgentRequest._(targets.single, standalone);
  }

  /// Match inside the actual account text, or its full pinyin for Latin queries.
  /// Parenthetical text remains part of that account, without generated aliases.
  bool matchesAccount(String account) =>
      _normal(account).contains(_normal(target)) ||
      AccountPinyin.contains(_normal(account), _normal(target));

  /// Preserve the online roster's order when several accounts contain the name.
  List<String> matchingAccounts(Iterable<String> accounts) => accounts
      .where(matchesAccount)
      .map((account) => account.trim())
      .toSet()
      .toList(growable: false);

  String? firstMatchingAccount(Iterable<String> accounts) {
    for (final account in accounts) {
      if (matchesAccount(account)) return account.trim();
    }
    return null;
  }

  static (String, bool)? _target(String raw) {
    var value = raw.trim().replaceFirst(RegExp(r'^(?:一下)?(?:给|到)?\s*'), '');
    value = value.replaceFirst(RegExp(r'^(?:客服(?:账号)?|同事|老师)\s*'), '');
    value = value.replaceFirst(
        RegExp(
            r'^(?:(?:the|customer service|support|service)\s+)?(?:agent|colleague)\s+',
            caseSensitive: false),
        '');
    value = value
        .replaceFirst(RegExp(r'^[“"‘\x27@：:]+'), '')
        .replaceFirst(RegExp(r'[”"’\x27]+$'), '');
    if (RegExp(r'或者|或是|还是|、|/|\band\b', caseSensitive: false).hasMatch(value) ||
        ((RegExp(r'[和与及或]').hasMatch(value)) &&
            '小'.allMatches(value).length > 1) ||
        RegExp(r'[A-Za-z0-9_]\s*[和与及或]\s*[A-Za-z0-9_]').hasMatch(value)) {
      return null;
    }
    final boundary = _extraContent.firstMatch(value);
    final extra = boundary == null ? '' : value.substring(boundary.start);
    if (boundary != null) value = value.substring(0, boundary.start);
    value = value.replaceFirst(_tailPoliteness, '').trim();
    value = value.replaceFirst(RegExp(r'(?:客服|同事|老师)$'), '').trim();
    // In an unqualified short request such as “转小耿阿”, 阿 is
    // commonly the typed sentence particle 啊, not part of the handle.
    if (RegExp(r'^小[\u3400-\u9fff]阿$').hasMatch(value)) {
      value = value.substring(0, value.length - 1);
    }
    value = _normal(value);
    if (!_plausible(value)) return null;
    return (value, extra.isEmpty);
  }

  static bool _onlyPoliteness(String text) {
    final value = text.trim().replaceFirst(_tailPoliteness, '').trim();
    return value.isEmpty || _politeness.hasMatch(value);
  }

  static bool _plausible(String name) =>
      name.length >= 2 &&
      name.length <= 40 &&
      RegExp(r'^[\u3400-\u9fffA-Za-z0-9_@ .：:()（）-]+$').hasMatch(name) &&
      !_generic.contains(name.toLowerCase()) &&
      !RegExp(r'不要|不用|别再|不想|不到|怎么|如何|为什么|问题|订单|退款|再转|转接|转给').hasMatch(name);

  static String _normal(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  static const _requestPrefix =
      r'(?:(?:请问|麻烦您|麻烦你|麻烦|请您|请你|请|帮我|帮忙|替我|给我|把我|将我|我想|我要|想要|希望|可不可以|能不能|可以|能否|能|现在|那么|还是|直接|那)\s*)*';
  static final _chineseAction = RegExp(
      '^$_requestPrefix(?:转接(?:给|到)?|转(?:给|到)?|换(?:成|给|到)?|接通|联系|找)\\s*(.+)\$');
  static final _assignedReception = RegExp(
      '^$_requestPrefix(?:让|叫|请)\\s*(.+?)\\s*(?:来)?(?:接待|接手|回复|处理|为我服务)(.*)\$');
  static final _englishAction = RegExp(
      r"^(?:(?:please|kindly|could you|can you|would you|i would like to|i'd like to|i want to|i need to|help me)\s+)*(?:transfer(?: me| this chat| the conversation)?|connect(?: me)?|switch(?: me)?|put me through|speak|talk)\s+(?:to|with)\s+(.+)$",
      caseSensitive: false);
  static final _romanizedAction =
      RegExp(r'^zhuan\s+(.+)$', caseSensitive: false);
  static final _negation = RegExp(
      r"不要|不用|别(?:再)?(?=转|找|让|联系|换|叫|请)|不想|无需|不需要|不转|不找|不让|不是|don['’]?t|do not|never|not\s+(?:to|with)",
      caseSensitive: false);
  static final _politeness = RegExp(
      r'^(?:你好|您好|谢谢(?:您|你)?|麻烦了|辛苦了|亲|please|thanks|thank you|hello|hi)$',
      caseSensitive: false);
  static final _tailPoliteness = RegExp(
      r'(?:\s*(?:一下|好吗|可以吗|行吗|谢谢(?:您|你)?|吧|呀|啊|吗|呢|please|thanks|thank you))+\s*$',
      caseSensitive: false);
  static final _extraContent = RegExp(
      r'帮我|帮忙|给我|为我|我想|我有|我的|打印机怎么|如何|为什么|接待|接手|办理|申请|退换货|退货|换货|退款|处理|解决|回复|看看|服务|\s+(?:because|about|regarding|and my|my printer|i have)\b',
      caseSensitive: false);
  static const _generic = <String>{
    '人工',
    '人工客服',
    '客服',
    '其他客服',
    '别的客服',
    '另一个客服',
    '其他',
    '别的',
    '另一个',
    '其他人',
    '别人',
    '个人',
    '在线',
    '在线客服',
    '专员',
    '负责人',
    '经理',
    '售后',
    '售前',
    '技术',
    '售后客服',
    '售前客服',
    '技术客服',
    '当前客服账号',
    '未知',
    'unknown',
    'self',
    'human',
    'ren gong',
    'rengong',
    'ke fu',
    'kefu',
    'ren gong ke fu',
    'rengongkefu',
    'human agent',
    'an agent',
    'a human',
    'someone else',
    'another agent',
    'other agent',
    'customer service',
    'support',
    '你们',
    '他们',
    '自己',
    '当前客服',
    '本客服',
  };
}
