import '../platform/macos_capture_adapter.dart';

/// Geometry shared by text and media extraction. Window headers and JD cards
/// are interface evidence, never customer-authored message content.
class OcrChatLayout {
  OcrChatLayout(this.inspection) {
    // Font/emoji controls can sit above the AX composer boundary. Use a
    // corroborated bottom toolbar, not an arbitrary percentage of the chat.
    final aa = inspection.observations.where((o) =>
        o.text.trim() == 'Aa' &&
        o.y > top + (bottom - top) * .70 &&
        o.y < bottom &&
        o.x >= left + (right - left) * .20 &&
        o.x < left + (right - left) * .42 &&
        o.width < .05 &&
        o.height < .035 &&
        !_hasMessageEvidence(o));
    for (final control in aa) {
      final peers = inspection.observations.where((o) =>
          o != control &&
          (o.y - control.y).abs() < .025 &&
          o.x >= left &&
          o.x < right &&
          o.height < .04 &&
          RegExp(r'^(?:[口囗□◉◎○+＋]|截图|发送|视频|文件|表情|图片|语音|字体|[A-Za-z]?[-|丨:：])')
              .hasMatch(o.text.trim()));
      // Aa itself is always chrome only at the documented font-control position.
      // A row of neighboring controls also excludes that toolbar's whole band.
      interfaceBands.add((
        control.y - .006,
        peers.isNotEmpty ? bottom : control.y + control.height + .006
      ));
    }
    // Vision may merge the whole icon row into one low-confidence token, for
    // example 口、Aa国画◎. Require the icon-only signature, font-control lane
    // and terminal toolbar geometry together. A customer image containing the
    // same row, or a sender-clock line, is not editor chrome.
    for (final control in inspection.observations.where(_mergedFontToolbar)) {
      final end = control.y + control.height + .006;
      interfaceBands.add((control.y - .006, end > bottom ? end : bottom));
    }
    final lines = inspection.observations.where(inTranscript).toList();
    // JD's recommendation overlay is interface text painted over the chat.
    // Require its heading plus a recommendation/control before masking its
    // actual occupied band; a customer mentioning these words stays prose.
    for (final header in lines.where((o) =>
        o.confidence >= .45 &&
        RegExp(r'^[★☆↓*]?\s*智能回复\s*[-—:：]').hasMatch(o.text.trim()))) {
      final recommendations = lines.where((o) =>
          o.y >= header.y &&
          o.y < header.y + .18 &&
          RegExp(r'推荐操作[:：]|您可以为顾客推荐|已选[（(]').hasMatch(o.text));
      final controls = lines.where((o) =>
          (o.y - header.y).abs() < .02 &&
          o.x > right - .10 &&
          RegExp(r'^\d+\s*s\s*[xX×]?$').hasMatch(o.text.trim()));
      if (recommendations.isEmpty && controls.isEmpty) continue;
      final end = recommendations.fold<double>(header.y + header.height,
          (value, o) => value > o.y + o.height ? value : o.y + o.height);
      interfaceBands.add((header.y - .004, (end + .006).clamp(top, bottom)));
    }
    for (final header in lines
        .where((o) => o.text.contains('上次会话小结') || o.text.trim() == '智能摘要')) {
      final fields = lines
          .where((o) =>
              o.y > header.y &&
              o.y < header.y + .35 &&
              RegExp(r'^(用户诉求|客服方案|商品\s*sku|咨询轨迹|承诺项)\s*[:：]',
                      caseSensitive: false)
                  .hasMatch(o.text.trim()))
          .toList();
      // Chrome belongs on the far-right of a full-width JD card. The same
      // words printed inside a customer screenshot must remain image content.
      final chrome = lines
          .where((o) =>
              (o.y - header.y).abs() < .025 &&
              o.x >= header.x + (right - left) * .35)
          .map((o) => o.text)
          .join(' ');
      final controls = chrome.contains('设置') && chrome.contains('收起');
      if (!controls) continue;
      final end = fields.fold<double>(header.y + header.height,
          (v, o) => v > o.y + o.height ? v : o.y + o.height);
      interfaceBands.add((header.y - .006, (end + .025).clamp(top, bottom)));
    }
  }
  final OcrInspection inspection;
  final List<(double, double)> interfaceBands = [];
  double get top => inspection.chatTop ?? 0;
  double get bottom => inspection.chatBottom ?? .90;
  double get left => inspection.chatLeft ?? .15;
  double get right => inspection.chatRight ?? .68;
  bool _hasMessageEvidence(OcrObservation item) =>
      hasSenderClock(item) ||
      [...inspection.visualRegions, ...inspection.unboundMediaRegions].any(
          (r) =>
              r.y >= top &&
              r.y + r.height <= bottom &&
              r.height >= item.height * 2 &&
              item.x >= r.x &&
              item.x + item.width <= r.x + r.width &&
              item.y >= r.y &&
              item.y + item.height <= r.y + r.height);

  bool _mergedFontToolbar(OcrObservation o) {
    final span = right - left;
    final terminalDepth = o.height * 2.5 > .035 ? o.height * 2.5 : .035;
    if (o.height <= 0 ||
        o.height >= .035 ||
        o.width < .06 ||
        o.width > span * .70 ||
        o.y <= top + (bottom - top) * .70 ||
        o.y < bottom - terminalDepth ||
        o.y >= bottom ||
        o.x < left - .006 ||
        o.x + o.width > right + .006 ||
        o.x > left + span * .42 ||
        o.x + o.width < left + span * .20 ||
        _hasMessageEvidence(o)) {
      return false;
    }
    final compact = o.text.replaceAll(RegExp(r'\s'), '');
    if ('Aa'.allMatches(compact).length != 1) return false;
    final icons = compact.replaceFirst('Aa', '');
    return RegExp(r'^[口囗□◉◎○+＋国画、，,。.·•|丨:：_\-—⏷⌄]+$').hasMatch(icons) &&
        RegExp(r'[口囗□◉◎○+＋国画]').allMatches(icons).length >= 3;
  }

  bool inTranscript(OcrObservation o) =>
      o.y >= top &&
      o.y + o.height / 2 < bottom &&
      o.x + o.width / 2 >= left &&
      o.x + o.width / 2 < right;
  bool isInterface(OcrObservation o) =>
      RegExp(r'^请尽快回复客户咨询[，,\s]*即将为客户推荐相似商品(?:哦)?[~～!！。]*$')
          .hasMatch(o.text.trim()) ||
      interfaceBands
          .any((b) => o.y + o.height / 2 >= b.$1 && o.y + o.height / 2 <= b.$2);
  bool hasSenderClock(OcrObservation item) {
    final clock = RegExp(r'(?<![0-9])\d{1,2}[:：]\d{2}(?::\d{2})?(?![0-9])');
    return clock.hasMatch(item.text) ||
        inspection.observations.any((other) =>
            (other.y - item.y).abs() <= .012 &&
            inTranscript(other) &&
            clock.hasMatch(other.text));
  }

  bool allowedMedia(OcrVisualRegion r) =>
      r.y >= top &&
      r.y + r.height <= bottom &&
      r.x >= left &&
      r.x + r.width <= right &&
      // Real customer bubbles begin near the left avatar. A long seller text
      // bubble can overlap the column centre, so testing its centre is unsafe.
      r.x <=
          left + (right - left) * (inspection.chatLeft == null ? .30 : .22) &&
      !interfaceBands.any((b) => r.y < b.$2 && r.y + r.height > b.$1);
}
