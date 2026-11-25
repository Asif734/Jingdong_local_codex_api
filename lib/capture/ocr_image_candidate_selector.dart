import '../platform/macos_capture_adapter.dart';
import 'ocr_chat_layout.dart';

/// Selects only visual regions owned by a customer message block. A region
/// cannot cross the next customer/seller sender label, which prevents outgoing
/// text bubbles from being promoted to incoming images.
class OcrImageCandidateSelector {
  const OcrImageCandidateSelector();

  List<OcrVisualRegion> select(
    OcrInspection inspection,
    String customer, {
    bool allowUnlabeledLatestImage = false,
    bool includeTextDense = false,
    bool onlyLatestCustomerBlock = false,
    Iterable<String> customerText = const [],
  }) {
    final layout = OcrChatLayout(inspection);
    final left = inspection.chatLeft ?? .15;
    final right = inspection.chatRight ?? .68;
    final bottom = inspection.chatBottom ?? .90;
    final senderLabels = inspection.observations
        .where((item) =>
            layout.inTranscript(item) &&
            !layout.isInterface(item) &&
            item.x + item.width / 2 >= left &&
            item.x + item.width / 2 < right &&
            ((_isCustomer(item.text, customer) &&
                    (inspection.chatLeft == null ||
                        layout.hasSenderClock(item))) ||
                _isSellerLabel(item, inspection)))
        .toList()
      ..sort((left, right) => left.y.compareTo(right.y));
    final selected = <OcrVisualRegion>[];
    for (var index = 0; index < senderLabels.length; index++) {
      final label = senderLabels[index];
      if (onlyLatestCustomerBlock && index != senderLabels.length - 1) continue;
      if (!_isCustomer(label.text, customer)) continue;
      final nextSenderY =
          index + 1 < senderLabels.length ? senderLabels[index + 1].y : .90;
      List<OcrVisualRegion> within(Iterable<OcrVisualRegion> candidates,
              {bool exact = false}) =>
          candidates
              .where((region) =>
                  _validGeometry(region, left, right) &&
                  layout.allowedMedia(region) &&
                  (includeTextDense ||
                      !isTextDense(region, inspection.observations)) &&
                  (exact
                      ? region.y >= label.y + label.height - .002
                      : label.y <= region.y + .012) &&
                  region.y - label.y <= .13 &&
                  region.y + region.height < nextSenderY - .002 &&
                  region.y + region.height <= bottom - (exact ? .002 : 0))
              .toList()
            ..sort(
                (a, b) => (b.width * b.height).compareTo(a.width * a.height));
      final verified =
          within(inspection.physicalMediaRegions ?? const [], exact: true);
      if (verified.isNotEmpty) {
        selected.add(verified.first);
        continue;
      }
      final proposed = within(
          [...inspection.visualRegions, ...inspection.unboundMediaRegions]);
      if (proposed.isNotEmpty) selected.add(proposed.first);
    }

    if (selected.isEmpty && allowUnlabeledLatestImage && senderLabels.isEmpty) {
      final unlabeled = inspection.visualRegions
          .where((region) =>
              _validGeometry(region, left, right) &&
              layout.allowedMedia(region))
          .where((region) =>
              includeTextDense || !isTextDense(region, inspection.observations))
          .where((region) =>
              region.x >= left &&
              // Customer media is left aligned. An unlabeled rectangle on the
              // seller side cannot be safely attributed to the customer.
              region.x <= left + (right - left) * .25 &&
              region.x + region.width <= right &&
              region.width >= .12 &&
              region.width <= .60 &&
              region.height >= .12)
          .toList();
      final outer = unlabeled.where((candidate) {
        return !unlabeled.any((container) {
          if (identical(candidate, container)) return false;
          const tolerance = .008;
          return container.x <= candidate.x + tolerance &&
              container.y <= candidate.y + tolerance &&
              container.x + container.width >=
                  candidate.x + candidate.width - tolerance &&
              container.y + container.height >=
                  candidate.y + candidate.height - tolerance &&
              container.width * container.height >
                  candidate.width * candidate.height * 1.25;
        });
      }).toList()
        ..sort((left, right) =>
            (right.y + right.height).compareTo(left.y + left.height));
      if (outer.isNotEmpty) selected.add(outer.first);
    }
    selected.removeWhere((region) =>
        isKnownTextBubble(region, inspection.observations, customerText));
    selected.sort((left, right) => right.y.compareTo(left.y));
    return selected;
  }

  /// Recover a missing outer image/placeholder within each verified incoming
  /// sender block. A later text bubble does not remove an earlier image from
  /// the frame. This only proposes acquisition rectangles: the registrar still
  /// needs AX arrival/ancestry proof before it can admit any business message.
  /// An empty OCR body needs a detector fragment or one unambiguous frozen
  /// image pin; a clipped text bubble must retain its text-clarification owner.
  ///
  /// Keep native full-card/video candidates unchanged. Some blank image cards
  /// expose only a narrow inner detector strip; normalize that strip to its
  /// empty sender block so loading and loaded observations have one proposal.
  List<OcrVisualRegion> recoverCustomerBlocks(
    OcrInspection inspection,
    String customer, {
    Iterable<OcrVisualRegion> owned = const [],
    Set<OcrVisualRegion>? recovered,
    bool hasPinnedImage = false,
  }) {
    final result = owned.toList();
    if (inspection.activeCustomerId != customer) return result;
    final layout = OcrChatLayout(inspection);
    bool insideKnownCard(OcrObservation line) {
      final cx = line.x + line.width / 2;
      final cy = line.y + line.height / 2;
      return [...result, ...inspection.unboundMediaRegions].any((card) =>
          cx >= card.x &&
          cx <= card.x + card.width &&
          cy >= card.y &&
          cy <= card.y + card.height);
    }

    final labels = inspection.observations
        .where((line) =>
            layout.inTranscript(line) &&
            !layout.isInterface(line) &&
            !line.isWatermark &&
            line.confidence >= .45 &&
            line.rotationDegrees.abs() <= 10 &&
            !insideKnownCard(line) &&
            layout.hasSenderClock(line) &&
            (_isCustomer(line.text, customer) ||
                _isSellerLabel(line, inspection)))
        .toList()
      ..sort((a, b) => a.y.compareTo(b.y));
    final proposals = <({
      OcrVisualRegion region,
      List<OcrVisualRegion> replaced,
      bool fragment,
      bool latestBlock,
    })>[];
    for (var index = 0; index < labels.length; index++) {
      final label = labels[index];
      if (!_isCustomer(label.text, customer)) continue;
      final start = label.y + label.height + .004;
      final end = _syntheticBlockEnd(
          layout,
          start,
          index + 1 < labels.length
              ? labels[index + 1].y - .004
              : layout.bottom);
      if (end - start < .07) continue;
      final inBlock = result
          .where((region) =>
              region.y >= label.y - .012 && region.y + region.height / 2 < end)
          .toList();
      // The native detector proved all four edges and select() already
      // checked the sender block. Width cannot revoke that proof.
      if (inBlock.any((region) =>
          inspection.physicalMediaRegions?.contains(region) == true ||
          region.width >= .07 ||
          inspection.unboundMediaRegions
              .any((play) => _sameCard(region, play)))) {
        continue;
      }
      if (inspection.unboundMediaRegions.any((play) =>
          play.y >= label.y - .012 && play.y + play.height / 2 < end)) {
        continue;
      }
      final candidate = OcrVisualRegion(
          x: label.x.clamp(layout.left, layout.right - .12).toDouble(),
          y: start,
          width: (layout.right - label.x).clamp(.12, .42).toDouble(),
          height: (end - start - .000001).clamp(.07, .60).toDouble(),
          confidence: 0);
      if (!layout.allowedMedia(candidate)) continue;
      if (_hasCustomerBody(candidate, inspection.observations, layout)) {
        continue;
      }
      final fragment = [
        ...inspection.visualRegions,
        ...inspection.unboundMediaRegions
      ].any((part) =>
          part.confidence >= .5 &&
          part.x >= layout.left &&
          part.x <= layout.left + (layout.right - layout.left) * .22 &&
          part.x + part.width <= layout.right &&
          part.y >= start - .004 &&
          part.y - label.y <= .13 &&
          part.y + part.height <= end + .002 &&
          part.width >= .025 &&
          part.height >= .025);
      proposals.add((
        region: candidate,
        replaced: inBlock,
        fragment: fragment,
        latestBlock: index == labels.length - 1,
      ));
    }
    // A missing OCR body may be clipped text, not an attachment. A frozen
    // image pin can identify only the single current bottom attachment; it
    // cannot convert older empty text blocks into independent image messages.
    final uniquePinnedBlock =
        hasPinnedImage && result.isEmpty && proposals.length == 1;
    for (final proposal in proposals) {
      if (!proposal.fragment && !(uniquePinnedBlock && proposal.latestBlock)) {
        continue;
      }
      result.removeWhere(proposal.replaced.contains);
      result.add(proposal.region);
      recovered?.add(proposal.region);
    }
    result.sort((a, b) => b.y.compareTo(a.y));
    return result;
  }

  /// Explicit native play proof survives a clipped sender header. Retain these
  /// as unbound observations, never infer their clock from a later text bubble.
  List<OcrVisualRegion> unboundCandidates(
      OcrInspection inspection, List<OcrVisualRegion> owned) {
    final layout = OcrChatLayout(inspection);
    return inspection.unboundMediaRegions
        .where((region) =>
            _validGeometry(region, layout.left, layout.right) &&
            layout.allowedMedia(region) &&
            !owned.any((other) => _sameCard(other, region)))
        .toList(growable: false);
  }

  bool _sameCard(OcrVisualRegion a, OcrVisualRegion b) {
    final left = a.x > b.x ? a.x : b.x;
    final top = a.y > b.y ? a.y : b.y;
    final right = a.x + a.width < b.x + b.width ? a.x + a.width : b.x + b.width;
    final bottom =
        a.y + a.height < b.y + b.height ? a.y + a.height : b.y + b.height;
    final small = a.width * a.height < b.width * b.height
        ? a.width * a.height
        : b.width * b.height;
    return right > left &&
            bottom > top &&
            small > 0 &&
            (right - left) * (bottom - top) / small >= .85 ||
        (a.x - b.x).abs() < .015 &&
            (a.y - b.y).abs() < .015 &&
            (a.width - b.width).abs() < .025 &&
            (a.height - b.height).abs() < .025;
  }

  /// Last-resort screenshot region for an incoming block when Vision did not
  /// emit a rectangle. This is bounded by sender labels, stays on the customer
  /// side, and rejects blocks containing ordinary message text.
  OcrVisualRegion? fallbackLatestCustomerBlock(
      OcrInspection inspection, String customer) {
    final layout = OcrChatLayout(inspection);
    final left = inspection.chatLeft ?? .15;
    final right = inspection.chatRight ?? .68;
    final bottom = inspection.chatBottom ?? .90;
    final labels = inspection.observations
        .where((item) =>
            layout.inTranscript(item) &&
            !layout.isInterface(item) &&
            item.x + item.width / 2 >= left &&
            item.x + item.width / 2 < right &&
            ((_isCustomer(item.text, customer) &&
                    (inspection.chatLeft == null ||
                        layout.hasSenderClock(item))) ||
                _isSellerLabel(item, inspection)))
        .toList()
      ..sort((a, b) => a.y.compareTo(b.y));

    for (var index = labels.length - 1; index >= 0; index--) {
      final label = labels[index];
      if (!_isCustomer(label.text, customer)) continue;
      final start = label.y + label.height + .004;
      // Keep the reconstructed region strictly inside its block. Floating
      // point addition can otherwise put e.g. .324 + .526 just above .85,
      // causing the valid header-only media region to be rejected entirely.
      final end = _syntheticBlockEnd(layout, start,
              index + 1 < labels.length ? labels[index + 1].y - .004 : bottom) -
          .000001;
      final height = end - start;
      if (height < .07) continue;
      final width = (right - left).clamp(.12, .42).toDouble();
      final candidate = OcrVisualRegion(
        x: left,
        y: start,
        width: width,
        height: height.clamp(.07, .60).toDouble(),
        confidence: 0,
      );
      // Missing high-confidence OCR is not an empty attachment. Even a
      // single uncertain character can be customer prose (e.g. "1" or "ok").
      // Only synthetic regions use this veto; native image/play detections
      // retain their normal classification path when their pixels contain text.
      if (!_hasCustomerBody(candidate, inspection.observations, layout,
              ignoreUnclockedSellerLabels: true) &&
          layout.allowedMedia(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  bool _validGeometry(OcrVisualRegion region, double left, double right) =>
      region.x >= left &&
      region.x + region.width <= right &&
      region.y >= .14 &&
      region.y + region.height <= .90 &&
      region.width >= .035 &&
      region.height >= .065 &&
      // JD's video previews can occupy about half of the captured window.
      // Rejecting them here prevents both capture and the unanswered-message
      // recovery path from ever seeing the new customer turn.
      region.width <= .60 &&
      region.height <= .76;

  /// A short rectangle covering already extracted customer prose is a text
  /// bubble, not a media receipt. Tall screenshots remain eligible, even when
  /// their contents contain text. Cache acquisition still verifies ownership.
  bool isKnownTextBubble(
      OcrVisualRegion r, List<OcrObservation> lines, Iterable<String> bodies) {
    if (r.height > .12 || bodies.isEmpty) return false;
    String compact(String s) => s.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    return lines.any((o) =>
        o.confidence >= .45 &&
        o.text.trim().length >= 6 &&
        o.x + o.width / 2 >= r.x &&
        o.x + o.width / 2 <= r.x + r.width &&
        o.y + o.height / 2 >= r.y &&
        o.y + o.height / 2 <= r.y + r.height &&
        bodies.any((body) => compact(body) == compact(o.text)));
  }

  bool isTextDense(OcrVisualRegion region, List<OcrObservation> observations) {
    final contained = observations.where((text) {
      final centerX = text.x + text.width / 2;
      final centerY = text.y + text.height / 2;
      return centerX >= region.x &&
          centerX <= region.x + region.width &&
          centerY >= region.y &&
          centerY <= region.y + region.height;
    }).toList(growable: false);
    if (contained.length < 2) return false;
    final characters = contained.fold<int>(
        0, (total, item) => total + item.text.replaceAll(' ', '').length);
    if (characters < 20) return false;
    final textArea = contained.fold<double>(
        0, (total, item) => total + item.width * item.height);
    final regionArea = region.width * region.height;
    return regionArea > 0 && textArea / regionArea >= .12;
  }

  /// A cache match is verified against the visible customer-owned pixels, so
  /// readable text inside that image is evidence about the image rather than
  /// evidence that the region is an ordinary chat bubble.
  bool shouldSaveImage(
    OcrVisualRegion region,
    List<OcrObservation> observations, {
    required bool fromVerifiedCache,
  }) =>
      fromVerifiedCache || !isTextDense(region, observations);

  double _syntheticBlockEnd(OcrChatLayout layout, double start, double end) {
    // A bottom editor toolbar terminates the transcript. Stop synthetic crops
    // before its mask; interior recommendation/summary masks still reject an
    // overlapping proposal through allowedMedia rather than truncating it.
    for (final band in layout.interfaceBands) {
      if (band.$1 <= start || band.$1 >= end || band.$2 < layout.bottom) {
        continue;
      }
      final fontToolbar = layout.inspection.observations.any((line) {
        if ((line.y - .006 - band.$1).abs() > .000001) return false;
        final token = line.text.replaceAll(RegExp(r'\s'), '');
        if ('Aa'.allMatches(token).length != 1) return false;
        final icons = token.replaceFirst('Aa', '');
        return icons.isEmpty ||
            RegExp(r'^[口囗□◉◎○+＋国画、，,。.·•|丨:：_\-—⏷⌄]+$').hasMatch(icons);
      });
      if (fontToolbar) end = band.$1;
    }
    return end;
  }

  bool _hasCustomerBody(OcrVisualRegion region,
      List<OcrObservation> observations, OcrChatLayout layout,
      {bool ignoreUnclockedSellerLabels = false}) {
    return observations.any((line) {
      final cx = line.x + line.width / 2;
      final cy = line.y + line.height / 2;
      if (cx < region.x ||
          cx > region.x + region.width ||
          cy < region.y ||
          cy > region.y + region.height ||
          _isRecoveryNoise(line, layout) ||
          (ignoreUnclockedSellerLabels && _isSeller(line.text))) {
        return false;
      }
      final text = line.text.trim();
      return text.isNotEmpty &&
          !RegExp(r'^\d{1,2}[:：]\d{2}(?::\d{2})?$').hasMatch(text) &&
          RegExp(r'[A-Za-z0-9\u3400-\u9fff]').hasMatch(text);
    });
  }

  bool _isRecoveryNoise(OcrObservation line, OcrChatLayout layout) {
    if (line.isWatermark || layout.isInterface(line)) return true;
    if (line.confidence < .75 && line.rotationDegrees.abs() > 10) return true;
    final text = line.text.replaceAll(RegExp(r'\s+'), '');
    final letters = text.replaceAll(RegExp(r'[^A-Za-z0-9\u3400-\u9fff]'), '');
    // The hover row beside a blank image may OCR as e.g. "•e •". Ordinary
    // horizontal customer prose still prevents fallback even at low OCR
    // confidence; low confidence alone never turns text into a media card.
    return line.confidence < .45 &&
        text.isNotEmpty &&
        letters.length / text.length < .5;
  }

  bool _isCustomer(String value, String customer) {
    final raw = value.toLowerCase().trim();
    final expected = customer.toLowerCase();
    if (raw == expected) return true;
    if (raw.startsWith(expected)) {
      final suffix = raw.substring(expected.length).trim();
      if (suffix.isEmpty || RegExp(r'\d{1,2}:\d{2}').hasMatch(suffix)) {
        return true;
      }
    }
    final prefix = raw
        .replaceAll('...', '')
        .replaceAll('…', '')
        .replaceAll(RegExp(r'\s+'), '');
    return prefix.length >= 6 && expected.startsWith(prefix);
  }

  bool _isSellerLabel(OcrObservation item, OcrInspection inspection) {
    if (!_isSeller(item.text)) return false;
    // Repeated diagonal watermarks look like account names. Only an actual
    // sender clock (merged or on the same line) may close a customer block.
    return OcrChatLayout(inspection).hasSenderClock(item);
  }

  bool _isSeller(String value) {
    final text = value.trim();
    return (text.contains('旗舰店') &&
            (text.contains(':') || text.contains('：'))) ||
        RegExp(r'格志打印机[\u3400-\u9fffA-Za-z0-9_-]{1,12}').hasMatch(text);
  }
}
