import 'dart:math' as math;

import '../platform/macos_capture_adapter.dart';
import 'ocr_chat_layout.dart';

/// One sender block in immutable pixels. The active customer is supplied by
/// AX; a damaged sender label can locate a block, never establish an identity
/// or a trustworthy clock. Admission still requires the frozen live frontier.
class IncomingMessageOwnershipEvidence {
  IncomingMessageOwnershipEvidence._(
      {OcrInspection? inspection,
      required this.customer,
      required this.header,
      required this.bodyRegion,
      required this.mediaContentRegion,
      required this.ordinal,
      required this.exactCustomerHeader,
      required this.latestIncomingBlock,
      required this.uniquePhysicalCard,
      required this.sentAt})
      : _inspection = inspection;

  final OcrInspection? _inspection;
  final String customer;
  final OcrObservation header;
  final OcrVisualRegion bodyRegion;
  final OcrVisualRegion mediaContentRegion;
  final int ordinal;
  final bool exactCustomerHeader;
  final bool latestIncomingBlock;
  final bool uniquePhysicalCard;
  final DateTime? sentAt;
  bool get explicitVideo => true;
  bool get ownsMedia => true;

  factory IncomingMessageOwnershipEvidence.fromMap(Map value) {
    OcrVisualRegion region(String key) {
      final box = (value[key] as List).cast<num>();
      if (box.length != 4) {
        throw const FormatException('ownership_region_invalid');
      }
      return OcrVisualRegion(
          x: box[0].toDouble(),
          y: box[1].toDouble(),
          width: box[2].toDouble(),
          height: box[3].toDouble(),
          confidence: 0);
    }

    final box = region('headerRegion');
    return IncomingMessageOwnershipEvidence._(
        customer: value['customer']! as String,
        header: OcrObservation(
            text: value['headerText']! as String,
            confidence: (value['headerConfidence'] as num?)?.toDouble() ?? 0,
            x: box.x,
            y: box.y,
            width: box.width,
            height: box.height,
            rotationDegrees:
                (value['headerRotation'] as num?)?.toDouble() ?? 0),
        bodyRegion: region('bodyRegion'),
        mediaContentRegion: region('mediaContentRegion'),
        ordinal: (value['headerOrdinal']! as num).toInt(),
        exactCustomerHeader: value['exactCustomerHeader'] == true,
        latestIncomingBlock: value['latestIncomingBlock'] == true,
        uniquePhysicalCard: value['uniquePhysicalCard'] == true,
        sentAt: DateTime.tryParse(value['senderAt']?.toString() ?? ''));
  }

  bool sameBlockAs(IncomingMessageOwnershipEvidence other) {
    final inspection = _inspection, otherInspection = other._inspection;
    // Restored geometry still needs the audit's own immutable pixel proof;
    // deserializing a map cannot manufacture same-frame ownership.
    if (inspection == null || otherInspection == null) return false;
    if (!uniquePhysicalCard ||
        !other.uniquePhysicalCard ||
        customer != other.customer ||
        ordinal != other.ordinal ||
        header.text != other.header.text ||
        !_sameBox(
            header.x,
            header.y,
            header.width,
            header.height,
            other.header.x,
            other.header.y,
            other.header.width,
            other.header.height) ||
        !_sameRegion(bodyRegion, other.bodyRegion) ||
        !_sameRegion(mediaContentRegion, other.mediaContentRegion) ||
        inspection.capturedAt != otherInspection.capturedAt ||
        inspection.imageWidth != otherInspection.imageWidth ||
        inspection.imageHeight != otherInspection.imageHeight) {
      return false;
    }
    final a = inspection.image, b = otherInspection.image;
    if (a.isEmpty || a.length != b.length) return false;
    if (identical(a, b)) return true;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Map<String, Object?> toMap() => {
        'version': 1,
        'customer': customer,
        'customerSource': 'active_ax_customer',
        'headerText': header.text,
        'headerConfidence': header.confidence,
        'headerRotation': header.rotationDegrees,
        'headerRegion': [header.x, header.y, header.width, header.height],
        'headerOrdinal': ordinal,
        'exactCustomerHeader': exactCustomerHeader,
        'latestIncomingBlock': latestIncomingBlock,
        'senderAt': sentAt?.toUtc().toIso8601String(),
        'bodyRegion': [
          bodyRegion.x,
          bodyRegion.y,
          bodyRegion.width,
          bodyRegion.height
        ],
        'mediaContentRegion': [
          mediaContentRegion.x,
          mediaContentRegion.y,
          mediaContentRegion.width,
          mediaContentRegion.height
        ],
        'explicitVideo': explicitVideo,
        'uniquePhysicalCard': uniquePhysicalCard,
      };
}

bool _sameBox(double x, double y, double width, double height, double bx,
        double by, double bw, double bh) =>
    (x - bx).abs() < .000001 &&
    (y - by).abs() < .000001 &&
    (width - bw).abs() < .000001 &&
    (height - bh).abs() < .000001;
bool _sameRegion(OcrVisualRegion a, OcrVisualRegion b) =>
    _sameBox(a.x, a.y, a.width, a.height, b.x, b.y, b.width, b.height);
double _overlap(OcrVisualRegion a, OcrVisualRegion b) {
  final width = math.min(a.x + a.width, b.x + b.width) - math.max(a.x, b.x);
  final height = math.min(a.y + a.height, b.y + b.height) - math.max(a.y, b.y);
  final area = math.min(a.width * a.height, b.width * b.height);
  return width <= 0 || height <= 0 || area <= 0 ? 0 : width * height / area;
}

class _Boundary {
  const _Boundary(this.line, this.incoming, this.exact);
  final OcrObservation line;
  final bool incoming;
  final bool exact;
}

/// Shared by clock binding, unknown detection and representation ownership.
/// A native outer rectangle may overlap a sender label. Its actual play-card
/// contents still belong below that label, and locate exactly one block.
class IncomingMessageOwnership {
  static final _clock = RegExp(r'(?<![0-9])\d{1,2}[:：]\d{2}[:：]\d{2}(?![0-9])');
  static String _compact(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), '').replaceAll('：', ':');

  /// Selected media and an undecoded sender block must agree on ownership.
  /// Testing the header's top allows a native outer border to overlap its
  /// own sender, while a preceding card cannot swallow a later text block.
  static bool occupiesBlock(OcrInspection view, String customer,
      {required OcrObservation header,
      required OcrVisualRegion bodyRegion,
      required Iterable<OcrVisualRegion> mediaRegions}) {
    if (view.activeCustomerId != customer) return false;
    final media = mediaRegions.toList(growable: false);
    final layout = OcrChatLayout(view);
    for (final card in media) {
      if (!layout.allowedMedia(card) ||
          card.width < .025 ||
          card.height < .04) {
        continue;
      }
      final proof = inspect(view, customer, card, physicalCards: media);
      if (proof != null) {
        if (_sameBox(
            header.x,
            header.y,
            header.width,
            header.height,
            proof.header.x,
            proof.header.y,
            proof.header.width,
            proof.header.height)) {
          return true;
        }
        continue;
      }
      final overlapTop = math.max(card.y, bodyRegion.y);
      final overlapBottom =
          math.min(card.y + card.height, bodyRegion.y + bodyRegion.height);
      if (card.y >= header.y - .008 &&
          card.y < bodyRegion.y + bodyRegion.height - .002 &&
          card.x < bodyRegion.x + bodyRegion.width &&
          card.x + card.width > bodyRegion.x &&
          overlapBottom - overlapTop >= math.min(.03, card.height * .35)) {
        return true;
      }
    }
    return false;
  }

  static IncomingMessageOwnershipEvidence? inspect(
      OcrInspection view, String customer, OcrVisualRegion region,
      {Iterable<OcrVisualRegion>? physicalCards}) {
    if (view.activeCustomerId != customer ||
        customer.isEmpty ||
        MacOSCaptureAdapter.isProvisionalIdentity(customer)) {
      return null;
    }
    final layout = OcrChatLayout(view);
    if (!layout.allowedMedia(region)) return null;
    final markers = <OcrVisualRegion>[];
    for (final marker in view.unboundMediaRegions) {
      if (!layout.allowedMedia(marker) ||
          marker.width < .035 ||
          marker.height < .04) {
        continue;
      }
      if (markers.every((old) => _overlap(old, marker) < .65)) {
        markers.add(marker);
      }
    }
    final matches =
        markers.where((marker) => _overlap(marker, region) >= .65).toList();
    if (matches.length != 1) return null;
    final media = matches.single;
    bool inMarker(OcrObservation line) => markers.any((marker) =>
        line.x + line.width / 2 >= marker.x &&
        line.x + line.width / 2 <= marker.x + marker.width &&
        line.y + line.height / 2 >= marker.y &&
        line.y + line.height / 2 <= marker.y + marker.height);
    final bounds = <_Boundary>[];
    for (final line in view.observations) {
      if (!layout.inTranscript(line) ||
          layout.isInterface(line) ||
          line.isWatermark ||
          line.rotationDegrees.abs() > 10 ||
          line.height > .065 ||
          inMarker(line)) {
        continue;
      }
      final text = _compact(line.text);
      final clock = _clock.firstMatch(line.text);
      final exact = line.confidence >= .45 &&
          _compact(line.text.replaceAll(_clock, '')) == _compact(customer) &&
          line.x < layout.left + (layout.right - layout.left) * .4 &&
          clock != null;
      // This is a weak sender-position witness only. It is not a corrected ID
      // and its clock is intentionally absent from the resulting evidence.
      final partial = line.confidence >= .25 &&
          line.confidence < .45 &&
          line.x >= layout.left &&
          line.x < layout.left + (layout.right - layout.left) * .15 &&
          clock != null &&
          RegExp(r'^[A-Za-z0-9]{1,6}_[A-Za-z0-9_-]{5,}(?:\s|$)')
              .hasMatch(line.text.trim());
      final seller = line.confidence >= .45 &&
          clock != null &&
          RegExp(r'格志打印机|旗舰店|其他客服').hasMatch(line.text) &&
          line.x >= layout.left + (layout.right - layout.left) * .5;
      final divider = line.confidence >= .25 &&
          RegExp(r'上次会话小结|历史会话小结|以下为新消息|以上为历史消息').hasMatch(line.text);
      if (!exact && !partial && !seller && !divider) continue;
      if (bounds.any((b) =>
          (b.line.y - line.y).abs() < .006 && _compact(b.line.text) == text)) {
        continue;
      }
      bounds.add(_Boundary(line, exact || partial, exact));
    }
    bounds.sort((a, b) => a.line.y.compareTo(b.line.y));
    final preceding = bounds.where((b) => b.line.y < media.y + .004).toList();
    if (preceding.isEmpty || !preceding.last.incoming) return null;
    final sender = preceding.last;
    final header = sender.line;
    final gap = media.y - header.y - header.height;
    if (gap > .08 || gap < -.012) return null;
    final index = bounds.indexOf(sender);
    final end = index + 1 < bounds.length
        ? math.min(layout.bottom, bounds[index + 1].line.y - .004)
        : layout.bottom;
    if (media.y + media.height > end + .006) return null;
    // The preceding text bubble cannot lend a readable header to a different
    // video. Reject actual prose between its header and the play-card content.
    if (view.observations.any((line) =>
        !line.isWatermark &&
        line.confidence >= .45 &&
        line.y >= header.y + header.height + .003 &&
        line.y + line.height <= media.y - .003 &&
        line.x >= layout.left &&
        line.x < layout.left + (layout.right - layout.left) * .55 &&
        RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(line.text) &&
        !layout.isInterface(line))) {
      return null;
    }
    final start = math.min(header.y + header.height + .004, media.y);
    if (end <= start) return null;
    final body = OcrVisualRegion(
        x: layout.left,
        y: start,
        width: (layout.right - layout.left).clamp(.12, .42).toDouble(),
        height: end - start - .000001,
        confidence: 0);
    final inBlock =
        markers.where((m) => m.y >= start - .006 && m.y < end).toList();
    final otherPhysical = (physicalCards ?? const <OcrVisualRegion>[]).where(
        (other) =>
            layout.allowedMedia(other) &&
            other.width >= .035 &&
            other.height >= .04 &&
            other.y >= start - .006 &&
            other.y < end &&
            _overlap(other, media) < .2);
    return IncomingMessageOwnershipEvidence._(
        inspection: view,
        customer: customer,
        header: header,
        bodyRegion: body,
        mediaContentRegion: media,
        ordinal: bounds.take(index).where((b) => b.incoming).length,
        exactCustomerHeader: sender.exact,
        latestIncomingBlock: !bounds.skip(index + 1).any((b) => b.incoming),
        uniquePhysicalCard: inBlock.length == 1 && otherPhysical.isEmpty,
        sentAt: sender.exact
            ? _parseClock(
                _clock.firstMatch(header.text)?.group(0), view.capturedAt)
            : null);
  }

  static DateTime? _parseClock(String? clock, DateTime capturedAt) {
    if (clock == null) return null;
    final parts = clock.replaceAll('：', ':').split(':').map(int.parse).toList();
    if (parts[0] > 23 || parts[1] > 59 || parts[2] > 59) return null;
    final day = capturedAt.toUtc().add(const Duration(hours: 8));
    var value =
        DateTime.utc(day.year, day.month, day.day, parts[0], parts[1], parts[2])
            .subtract(const Duration(hours: 8));
    if (value.difference(capturedAt.toUtc()) > const Duration(minutes: 1)) {
      value = value.subtract(const Duration(days: 1));
    }
    return value;
  }
}
