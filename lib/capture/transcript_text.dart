/// Recognizable JD sender chrome is not a customer/seller message. Retain real
/// questions about the brand; only label-only fragments and merged greetings
/// are cleaned. Raw screenshot evidence remains unchanged.
class TranscriptText {
  static final _label = RegExp(
      r'^(?:[“”"「」◎●◉·:：\s-]*(?:格志打印(?:机|料|材)?(?:小[\u3400-\u9fff]{0,4})?|ま打印机小[\u3400-\u9fff]{0,4}))+[“”"「」◎●◉·:：\s-]*$');
  static final _mergedGreeting = RegExp(
      r'^(hi+|hello|hey|ok(?:ay)?|thanks|thank you)[!！,.，\s]*(格志打印(?:机|料|材)?(?:小[\u3400-\u9fff]{0,4})?)[!！,.，\s]*$',
      caseSensitive: false);

  static String customerQuestionSummary(String raw) {
    final text = raw.trim();
    if (RegExp(r'\[(?:Customer sent|Video|Image|Audio)', caseSensitive: false)
        .hasMatch(text)) {
      return '';
    }
    final compact = text.replaceAll(RegExp(r'\s+'), ' ');
    return compact.length <= 80 ? compact : '${compact.substring(0, 80)}…';
  }

  static bool hasDeliveryRejection(String text) {
    final compact = text.replaceAll(RegExp(r'[\s，,。.!！]'), '');
    return compact.endsWith('该顾客正在咨询其他客服无法回复顾客消息') ||
        compact.endsWith('当前客户由其他客服接待无法回复顾客消息');
  }

  static String clean(String value) {
    var text = value.trim();
    // Only separated JD chrome; customer prose such as “查看更多选项” stays.
    text = text
        .replaceFirst(
            RegExp(r'\s+(?:更多|查看更多[~～]?|引用|L-\s*AO\s*[·.]\s*Q\s*O)\s*$'), '')
        .trim();
    if (RegExp(r'^(?:更多|查看更多[~～]?|引用|暂停[|丨].{0,5})$').hasMatch(text)) return '';

    if (RegExp(r'^请尽快回复客户咨询[，,\s]*即将为客户推荐相似商品(?:哦)?[~～!！。]*$').hasMatch(text) ||
        RegExp(r'^[口囗□]\s*[:：、]$').hasMatch(text)) {
      return '';
    }

    // Label-only punctuation variants are chrome, never a language switch.
    final labelText = text.replaceAll(RegExp(r'[!！。.,，/／|丨]+$'), '').trim();
    if (_label.hasMatch(labelText)) return '';

    if (RegExp(
            r'^[“”"◎●◉·\s-]*(?:格[志患惠]打印(?:机|料|材)?(?:[小门にの][\u3400-\u9fffA-Za-z0-9_-]{0,4})?|[#＃-]?[女ま]?打印机小[\u3400-\u9fffA-Za-z0-9_-]{0,4})[“”"◎●◉·\s-]*$')
        .hasMatch(text)) {
      return '';
    }

    // Font/play controls beside thumbnails can be recognized as short mixed
    // strings (recorded example: 口、Aa国Q◎). Preserve real short questions.
    if (RegExp(r'[◎◉○□▣•·]').hasMatch(text) &&
        RegExp(r'^[\s、,.，:：;；AaQq口回国图目曰囗田◎◉○□▣•·]+$').hasMatch(text)) {
      return '';
    }
    final notice = text.indexOf('当前会话您存在消极服务行为');
    if (notice >= 0 &&
        RegExp(r'平台[已己]记录信息.*规则').hasMatch(text.substring(notice))) {
      final prefix = text.substring(0, notice).trim();
      // Only a standalone JD banner or a banner appended to our holding.
      // Customer questions quoting a notice remain customer content.
      if (prefix.isEmpty ||
          RegExp(r'^(?:请稍等|请您稍等|Please wait|One moment|I[’\x27]m checking)',
                  caseSensitive: false)
              .hasMatch(prefix)) {
        text = prefix;
      }
    }
    if (_label.hasMatch(text) || RegExp(r'^格志打印机[/／|丨]+$').hasMatch(text)) {
      return '';
    }
    final questionWithChrome =
        RegExp(r'^(.*[?？!！。])\s+(格志打印(?:机|料|材)?(?:小[\u3400-\u9fff]{0,4})?)$')
            .firstMatch(text);
    if (questionWithChrome != null) return questionWithChrome.group(1)!;
    final greeting = _mergedGreeting.firstMatch(text);
    return greeting?.group(1) ?? text;
  }
}
