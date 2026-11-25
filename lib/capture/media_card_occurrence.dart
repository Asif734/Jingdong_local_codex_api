import '../platform/macos_capture_adapter.dart';

/// Structure in one immutable chat frame, not a platform message identifier.
/// It can prove that a video card kept its owner while its cover loaded or its
/// visible crop changed. It must not deduplicate independently sent assets.
class MediaCardOccurrenceContext {
  MediaCardOccurrenceContext._(this._value);
  final Map<String, Object?> _value;

  factory MediaCardOccurrenceContext.fromMap(Map value) =>
      MediaCardOccurrenceContext._(
          value.map((key, value) => MapEntry('$key', value)));

  Map<String, Object?> toMap() => Map.of(_value);

  static String _compact(String value) =>
      value.toLowerCase().replaceAll('：', ':').replaceAll(RegExp(r'\s+'), '');
  static final _clock = RegExp(r'\d{1,2}:\d{2}:\d{2}');

  static double _overlap(OcrVisualRegion a, OcrVisualRegion b) {
    double min(double a, double b) => a < b ? a : b;
    double max(double a, double b) => a > b ? a : b;
    final width = min(a.x + a.width, b.x + b.width) - max(a.x, b.x);
    final height = min(a.y + a.height, b.y + b.height) - max(a.y, b.y);
    final area = min(a.width * a.height, b.width * b.height);
    return width <= 0 || height <= 0 || area <= 0 ? 0 : width * height / area;
  }

  factory MediaCardOccurrenceContext.inspect(
      OcrInspection view, String customer, OcrVisualRegion card,
      {Iterable<OcrVisualRegion>? physicalCards}) {
    final left = view.chatLeft ?? .24,
        right = view.chatRight ?? .75,
        top = view.chatTop ?? .2,
        bottom = view.chatBottom ?? .81;
    bool inside(OcrObservation line) =>
        !line.isWatermark &&
        line.confidence >= .45 &&
        line.x >= left &&
        line.x < right &&
        line.y >= top - .004 &&
        line.y < bottom;
    final lines = view.observations.where(inside).toList()
      ..sort((a, b) => a.y.compareTo(b.y));
    // Vision often assigns 0.3 to JD's stylized summary title. It may locate
    // a divider, but cannot prove one alone: conflict checks below also need
    // matching high-confidence summary body anchors. Sender thresholds stay.
    final dividerTitles = view.observations.where((line) =>
        !line.isWatermark &&
        line.confidence >= .25 &&
        line.confidence < .45 &&
        line.x >= left &&
        line.x < right &&
        line.y >= top - .004 &&
        line.y < bottom &&
        RegExp(r'上次会话小结|历史会话小结|以下为新消息|以上为历史消息').hasMatch(_compact(line.text)));
    final boundaries = <_CardBoundary>[];
    for (final line in [...lines, ...dividerTitles]) {
      final text = _compact(line.text);
      // A session-summary card is chrome between real bubbles. Its picture
      // cannot inherit the sender above the summary as a new incoming video.
      if (RegExp(r'上次会话小结|历史会话小结|以下为新消息|以上为历史消息').hasMatch(text)) {
        boundaries.add(_CardBoundary(
            'divider:${RegExp(r'上次会话小结|历史会话小结|以下为新消息|以上为历史消息').firstMatch(text)![0]}',
            'divider',
            line.y,
            line.y + line.height));
        continue;
      }
      final incoming = text.startsWith(_compact(customer));
      final seller = !incoming && RegExp(r'格志打印机|旗舰店|其他客服').hasMatch(text);
      if (!incoming && !seller) continue;
      var clock = _clock.firstMatch(text)?.group(0);
      // Vision may keep the name and clock in separate boxes on one line.
      if (clock == null) {
        final clocks = lines.where((other) =>
            (other.y + other.height / 2 - line.y - line.height / 2).abs() <
                .009 &&
            RegExp(r'^\d{1,2}:\d{2}:\d{2}$').hasMatch(_compact(other.text)));
        if (clocks.length == 1) clock = _compact(clocks.single.text);
      }
      if (clock == null) continue;
      final name = incoming
          ? _compact(customer)
          : text.replaceAll(_clock, '').replaceAll('其他客服', '');
      final key = '${incoming ? 'incoming' : 'seller'}:$name:$clock';
      // Avoid counting split/overlapping OCR copies as independent headers.
      if (boundaries
          .any((old) => old.key == key && (old.top - line.y).abs() < .008)) {
        continue;
      }
      boundaries.add(_CardBoundary(
          key, incoming ? 'incoming' : 'seller', line.y, line.y + line.height));
    }
    boundaries.sort((a, b) => a.top.compareTo(b.top));
    final possible =
        boundaries.where((line) => line.top <= card.y + .008).toList();
    final header = possible.lastOrNull;
    final index = header == null ? -1 : boundaries.indexOf(header);
    final preceding = index > 0 ? boundaries[index - 1] : null;
    final next = index >= 0 && index + 1 < boundaries.length
        ? boundaries[index + 1]
        : null;
    final precedingText = preceding == null || header == null
        ? const <String>[]
        : lines
            .where((line) =>
                line.y >= preceding.bottom - .002 &&
                line.y + line.height / 2 < header.top &&
                line.confidence >= .75)
            .map((line) => _compact(line.text))
            // Tiny status marks and moving pale watermarks prove no ancestry.
            .where((text) => text.length >= 12)
            .toList();

    final cards = <OcrVisualRegion>[];
    final candidates = [
      card,
      if (physicalCards != null)
        ...physicalCards
      else ...[
        ...view.unboundMediaRegions,
        ...view.visualRegions,
      ],
    ]..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    for (final candidate in candidates) {
      if (candidate.x < left ||
          candidate.x >= left + (right - left) * .65 ||
          candidate.y < top - .025 ||
          candidate.y >= bottom ||
          candidate.width < .035 ||
          candidate.height < .04 ||
          (header != null && candidate.y < header.top - .008) ||
          (next != null && candidate.y >= next.top - .002)) {
        continue;
      }
      // Native rectangle detection also returns play buttons and sub-crops
      // inside one video. Containment is one representation, not a new slot.
      if (cards.every((old) => _overlap(candidate, old) < .65)) {
        cards.add(candidate);
      }
    }
    cards.sort((a, b) => a.y.compareTo(b.y));
    final slot = cards.indexWhere((other) => _overlap(other, card) >= .65);
    return MediaCardOccurrenceContext._({
      'version': physicalCards == null ? 1 : 2,
      'cardCountSource': physicalCards == null
          ? 'native_region_proposals'
          : 'selected_physical_candidates',
      'customer': customer,
      'customerVerified': view.activeCustomerId == customer,
      'headerKey': header?.kind == 'incoming' ? header?.key : null,
      'headerTop': header?.top,
      'headerBottom': header?.bottom,
      'headerCount': header == null
          ? 0
          : boundaries.where((other) => other.key == header.key).length,
      'headerOrdinal': header == null
          ? null
          : boundaries
              .take(index)
              .where((other) => other.key == header.key)
              .length,
      'otherIncomingKeys': [
        for (final boundary in boundaries)
          if (boundary.kind == 'incoming' && boundary != header) boundary.key,
      ],
      'precedingKey': preceding?.key,
      'precedingText': precedingText,
      'leadingText': header == null
          ? const <String>[]
          : lines
              .where((line) =>
                  line.y + line.height / 2 < header.top &&
                  line.confidence >= .75)
              .map((line) => _compact(line.text))
              .where((text) => text.length >= 12 && !_clock.hasMatch(text))
              .toList(),
      'nextKey': next?.key,
      'originalHeaderLabels': [
        if (header?.kind == 'incoming')
          for (final line in _timestampAnchors(view, customer))
            if ((line.y - header!.top).abs() < .008) _compact(line.text),
      ],
      'followingTimestampLines': [
        if (next != null && next.kind != 'divider')
          for (final line in _timestampAnchors(view, customer))
            if ((line.y - next.top).abs() < .008 &&
                line.y >= card.y + card.height - .012)
              {'text': _compact(line.text), 'x': line.x, 'y': line.y},
      ],
      'followingSellerLines': [
        for (final line in _sellerAnchors(view))
          if (line.y >= card.y + card.height - .018 &&
              line.y < card.y + card.height + .18 &&
              (next == null || next.kind == 'seller' || line.y < next.top) &&
              _sellerAnchors(view)
                      .where(
                          (item) => _compact(item.text) == _compact(line.text))
                      .length ==
                  1)
            {'text': _compact(line.text), 'x': line.x, 'y': line.y},
      ],
      'cardTopOffset': header == null ? null : card.y - header.bottom,
      'transcriptWidth': right - left,
      'transcriptLeft': left,
      'cardX': card.x,
      'cardWidth': card.width,
      'cardSlot': slot,
      'cardCount': cards.length,
      'explicitVideo': view.activeCustomerId == customer &&
          view.unboundMediaRegions.any((other) => _overlap(card, other) >= .65),
      'dividers': [
        for (final boundary in boundaries)
          if (boundary.kind == 'divider')
            {
              'key': boundary.key,
              'side': boundary.top < card.y ? 'before' : 'after',
              'anchors': lines
                  .where((line) =>
                      line.y >= boundary.bottom - .002 &&
                      line.y <
                          (boundaries
                                  .where((next) => next.top > boundary.top)
                                  .firstOrNull
                                  ?.top ??
                              bottom) &&
                      line.confidence >= .75)
                  .map((line) => _compact(line.text))
                  .where((text) => text.length >= 8)
                  .toList(),
            },
      ],
    });
  }

  static Iterable<OcrObservation> _sellerAnchors(OcrInspection view) {
    final left = view.chatLeft ?? .24, right = view.chatRight ?? .75;
    return view.observations.where((line) =>
        !line.isWatermark &&
        line.confidence >= .75 &&
        line.x >= left + (right - left) * .22 &&
        line.x + line.width >= left + (right - left) * .80 &&
        line.x + line.width <= right + .01 &&
        line.y >= (view.chatTop ?? .2) &&
        line.y < (view.chatBottom ?? .81) &&
        _compact(line.text).length >= 14 &&
        !_clock.hasMatch(_compact(line.text)));
  }

  static Iterable<OcrObservation> _timestampAnchors(
      OcrInspection view, String customer) {
    final left = view.chatLeft ?? .24, right = view.chatRight ?? .75;
    final sender = RegExp('^${RegExp.escape(_compact(customer))}'
        r'\d{1,2}:\d{2}:\d{2}$');
    return view.observations.where((line) {
      if (line.isWatermark ||
          line.confidence < .45 ||
          line.x < left ||
          line.x + line.width > right + .01 ||
          line.y < (view.chatTop ?? .2) ||
          line.y >= (view.chatBottom ?? .81)) return false;
      final text = _compact(line.text);
      return sender.hasMatch(text) ||
          (line.x >= left + (right - left) * .45 &&
              _clock.hasMatch(text) &&
              RegExp(r'格志打印机|旗舰店|其他客服').hasMatch(text));
    });
  }

  /// Recover geometry only. A cache pixel match is required before this
  /// projection can enrich the original time-keyed message.
  OcrVisualRegion? projectClippedCard(
      OcrInspection view, OcrVisualRegion oldCard) {
    if (_value['customerVerified'] != true ||
        view.activeCustomerId != _value['customer'] ||
        (view.chatLeft ?? .24) > oldCard.x) return null;
    final left = view.chatLeft ?? .24, right = view.chatRight ?? .75;
    if (((_value['transcriptWidth'] as num? ?? right - left) - (right - left))
                .abs() >
            .015 ||
        ((_value['transcriptLeft'] as num? ?? left) - left).abs() > .01)
      return null;
    final timeLines = _timestampAnchors(view, view.activeCustomerId!).toList();
    final originalLabels = _value['originalHeaderLabels'] as List? ?? const [];
    // If the original sender header is still visible, use the normal owned
    // card path. The later header never assigns a new business timestamp.
    if (timeLines.any((line) => originalLabels.contains(_compact(line.text)))) {
      return null;
    }
    final anchors = [
      ...(_value['followingSellerLines'] as List? ?? const []),
      ...(_value['followingTimestampLines'] as List? ?? const []),
    ].whereType<Map>();
    final lines = [..._sellerAnchors(view), ...timeLines];
    final shifts = <double>[];
    for (final anchor in anchors) {
      final matches = lines.where((line) =>
          _compact(line.text) == anchor['text'] &&
          (line.x - (anchor['x'] as num)).abs() < .015);
      if (matches.length == 1) {
        shifts.add(matches.single.y - (anchor['y'] as num));
      }
    }
    if (shifts.isEmpty || shifts.any((v) => (v - shifts.first).abs() > .012)) {
      return null;
    }
    final shift = shifts.first;
    final top = view.chatTop ?? .2;
    // Detector boxes often stop several pixels before the rounded lower
    // edge. Include a small margin below it; native matching trims it.
    final projectedBottom = oldCard.y + oldCard.height + shift + .006;
    final height = projectedBottom - top;
    if (shift >= -.02 ||
        oldCard.y + shift >= top - .004 ||
        height < .025 ||
        height > oldCard.height * .85) return null;
    return OcrVisualRegion(
        x: oldCard.x,
        y: top,
        width: oldCard.width,
        height: height,
        confidence: 1);
  }

  /// This proves a visible incoming card, not a unique platform timestamp.
  /// Two cards with identical clocks still start with different observation
  /// groups. Only a separately proved continuation may reuse either group.
  bool get hasVerifiedIncomingCard {
    final offset = (_value['cardTopOffset'] as num?)?.toDouble();
    return _value['customerVerified'] == true &&
        _value['headerKey'] is String &&
        (_value['headerCount'] as num? ?? 0) > 0 &&
        (_value['cardSlot'] as num? ?? -1) >= 0 &&
        offset != null &&
        offset >= -.025 &&
        offset <= .08;
  }

  /// A visual resemblance cannot override explicit evidence that the cards
  /// occupy different incoming blocks or opposite sides of the same divider.
  /// Missing headers are unknown; they do not manufacture a conflict.
  bool conflictsWith(MediaCardOccurrenceContext previous) {
    final a = previous._value, b = _value;
    if (a['customerVerified'] != true || b['customerVerified'] != true) {
      return false;
    }
    if (a['customer'] != b['customer']) return true;
    if (a['headerKey'] != null && b['headerKey'] != null) {
      // A changed OCR clock alone is not another message. A different block
      // is explicit when the other's own header is separately visible here.
      if (a['headerKey'] != b['headerKey'] &&
          (((a['otherIncomingKeys'] as List? ?? const [])
                  .contains(b['headerKey'])) ||
              ((b['otherIncomingKeys'] as List? ?? const [])
                  .contains(a['headerKey'])))) {
        return true;
      }
    }
    if (a['headerKey'] != null && a['headerKey'] == b['headerKey']) {
      if ((a['headerCount'] as num? ?? 0) > 1 &&
          a['headerCount'] == b['headerCount'] &&
          a['headerOrdinal'] != b['headerOrdinal']) {
        return true;
      }
      final beforeA = a['precedingKey'], beforeB = b['precedingKey'];
      if (beforeA != null &&
          beforeB != null &&
          beforeA != beforeB &&
          (beforeA == a['headerKey'] || beforeB == b['headerKey'])) {
        return true;
      }
    }
    final oldDividers = (a['dividers'] as List? ?? const []).whereType<Map>();
    final newDividers = (b['dividers'] as List? ?? const []).whereType<Map>();
    for (final old in oldDividers) {
      final oldSame = oldDividers.where((d) => d['key'] == old['key']);
      final newSame = newDividers.where((d) => d['key'] == old['key']);
      if (oldSame.length != 1 || newSame.length != 1) continue;
      final next = newSame.single;
      if (old['side'] == next['side']) continue;
      // Repeated summary titles are not a global boundary ID. Their visible
      // body must also establish that this is the same intervening summary.
      if (old['key'].toString().contains('会话小结') &&
          !_sharedText(old['anchors'], next['anchors'])) {
        continue;
      }
      return true;
    }
    return false;
  }

  static bool _sharedText(Object? a, Object? b) =>
      (a is List ? a.toSet() : const <Object>{})
          .intersection(b is List ? b.toSet() : const <Object>{})
          .isNotEmpty;

  /// Structure is a candidate proof for a re-read image. The caller must also
  /// verify its pixels. Sender seconds or shared asset bytes alone never join
  /// two messages. Neighbouring prose/divider anchors disambiguate the block.
  bool sameIncomingImageBlock(MediaCardOccurrenceContext previous) {
    final a = previous._value, b = _value;
    if (!hasVerifiedIncomingCard ||
        !previous.hasVerifiedIncomingCard ||
        conflictsWith(previous) ||
        a['headerCount'] != b['headerCount'] ||
        a['headerOrdinal'] != b['headerOrdinal'] ||
        a['cardSlot'] != b['cardSlot'] ||
        a['cardCount'] != b['cardCount']) {
      return false;
    }
    var contextMatches = _sharedText(a['leadingText'], b['leadingText']);
    final oldDividers = (a['dividers'] as List? ?? const []).whereType<Map>();
    final newDividers = (b['dividers'] as List? ?? const []).whereType<Map>();
    for (final old in oldDividers) {
      if (newDividers.any((next) =>
          old['key'] == next['key'] &&
          old['side'] == next['side'] &&
          _sharedText(old['anchors'], next['anchors']))) {
        contextMatches = true;
      }
    }
    if (!contextMatches) return false;
    final oldOffset = (a['cardTopOffset'] as num?)?.toDouble();
    final newOffset = (b['cardTopOffset'] as num?)?.toDouble();
    final oldX = (a['cardX'] as num?)?.toDouble();
    final newX = (b['cardX'] as num?)?.toDouble();
    return oldOffset != null &&
        newOffset != null &&
        oldX != null &&
        newX != null &&
        (oldOffset - newOffset).abs() <= .025 &&
        (oldX - newX).abs() <= .015;
  }

  /// The sender block owns the video. A foreground crop may begin anywhere
  /// inside its loading/loaded card, so its top is not a business identity.
  /// Callers must additionally verify the physical card in immutable frames.
  bool sameSingleIncomingVideoBlock(MediaCardOccurrenceContext previous,
      {bool verifiedSameSenderGlyphs = false}) {
    final a = previous._value, b = _value;
    return a['customerVerified'] == true &&
        b['customerVerified'] == true &&
        a['customer'] == b['customer'] &&
        a['headerKey'] != null &&
        (a['headerKey'] == b['headerKey'] || verifiedSameSenderGlyphs) &&
        !conflictsWith(previous) &&
        a['headerCount'] == 1 &&
        b['headerCount'] == 1 &&
        a['cardCount'] == 1 &&
        b['cardCount'] == 1 &&
        a['cardSlot'] == 0 &&
        b['cardSlot'] == 0 &&
        a['precedingKey'] != null &&
        a['precedingKey'] == b['precedingKey'] &&
        _sharedText(a['precedingText'], b['precedingText']);
  }

  /// This is an additional positive VIDEO proof. A false result leaves the
  /// pre-existing pixel matcher unchanged, including ordinary-image policy.
  bool continuesVideo(MediaCardOccurrenceContext previous,
      {bool verifiedVideoParent = false}) {
    final a = previous._value, b = _value;
    if (!verifiedVideoParent &&
        a['explicitVideo'] != true &&
        b['explicitVideo'] != true) {
      return false;
    }
    if (a['customer'] != b['customer'] ||
        a['customerVerified'] != true ||
        b['customerVerified'] != true ||
        a['headerKey'] == null ||
        a['headerKey'] != b['headerKey'] ||
        a['headerCount'] != 1 ||
        b['headerCount'] != 1 ||
        a['precedingKey'] == null ||
        a['precedingKey'] != b['precedingKey'] ||
        a['cardCount'] != 1 ||
        b['cardCount'] != 1 ||
        a['cardSlot'] != 0 ||
        b['cardSlot'] != 0) {
      return false;
    }
    final oldText = (a['precedingText'] as List? ?? const []).toSet();
    final newText = (b['precedingText'] as List? ?? const []).toSet();
    if (oldText.intersection(newText).isEmpty) return false;
    final oldDividers = (a['dividers'] as List? ?? const []).whereType<Map>();
    final newDividers = (b['dividers'] as List? ?? const []).whereType<Map>();
    for (final old in oldDividers) {
      if (newDividers.any(
          (next) => old['key'] == next['key'] && old['side'] != next['side'])) {
        return false;
      }
    }
    double? number(Map value, String key) => (value[key] as num?)?.toDouble();
    final oldOffset = number(a, 'cardTopOffset'),
        newOffset = number(b, 'cardTopOffset'),
        oldX = number(a, 'cardX'),
        newX = number(b, 'cardX'),
        oldWidth = number(a, 'cardWidth'),
        newWidth = number(b, 'cardWidth');
    return oldOffset != null &&
        newOffset != null &&
        oldX != null &&
        newX != null &&
        oldWidth != null &&
        newWidth != null &&
        oldWidth > 0 &&
        newWidth > 0 &&
        (oldOffset - newOffset).abs() <= .025 &&
        (oldX - newX).abs() <= .015 &&
        oldWidth / newWidth >= .65 &&
        oldWidth / newWidth <= 1.54;
  }
}

class _CardBoundary {
  const _CardBoundary(this.key, this.kind, this.top, this.bottom);
  final String key, kind;
  final double top, bottom;
}
