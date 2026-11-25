import '../domain/capture_models.dart';
import '../platform/macos_capture_adapter.dart';

/// One frozen customer's contiguous message block may contain a video and its
/// separate caption. Geometry proves the association; clock proximity does not.
class MediaCaptionDependency {
  static Map<String, Set<String>> inferScope(
      OcrInspection inspection,
      String customer,
      Iterable<CapturedMessage> messages,
      Map<OcrVisualRegion, String> receipts,
      {Set<String> independentMessageIds = const {}}) {
    final related = <String>{};
    final members = <String>{};
    for (final entry in receipts.entries) {
      final linked = infer(
          inspection, customer, messages, {entry.key: entry.value},
          independentMessageIds: independentMessageIds);
      if (linked.isNotEmpty) {
        related.addAll(linked.keys);
        members.add(entry.value);
      }
    }
    // A caption belongs to the current unanswered media scope. It need not
    // contain a selected verb and does not pick one of several cards by clock.
    return {for (final id in related) id: members};
  }

  static Map<String, String> infer(
      OcrInspection inspection,
      String customer,
      Iterable<CapturedMessage> messages,
      Map<OcrVisualRegion, String> ownedReceipts,
      {Iterable<OcrVisualRegion> unbound = const [],
      Set<String> independentMessageIds = const {}}) {
    final left = inspection.chatLeft ?? .24;
    final right = inspection.chatRight ?? .75;
    final top = inspection.chatTop ?? .2;
    final bottom = inspection.chatBottom ?? .81;
    final clock = RegExp(r'\d{1,2}[:：]\d{2}[:：]\d{2}');
    final sellerHeaders = inspection.observations.where((line) =>
        line.y >= top &&
        line.y < bottom &&
        line.x >= left &&
        line.x < right &&
        clock.hasMatch(line.text) &&
        !line.text.contains(customer) &&
        RegExp(r'格志打印机|旗舰店|其他客服').hasMatch(line.text));
    final start = sellerHeaders.fold<double>(
        top, (value, line) => line.y > value ? line.y : value);
    final cards = ownedReceipts.entries
        .where((entry) =>
            entry.key.y > start &&
            entry.key.y + entry.key.height <= bottom + .01)
        .toList();
    if (cards.length != 1 || unbound.any((card) => card.y > start)) return {};
    final card = cards.single;
    String compact(String text) =>
        text.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final result = <String, String>{};
    for (final message in messages) {
      if (message.direction != 'incoming' ||
          message.media.isNotEmpty ||
          independentMessageIds.contains(message.stableId)) {
        continue;
      }
      final body = compact(message.body);
      final lines = inspection.observations.where((line) =>
          line.confidence >= .45 &&
          line.x >= left &&
          line.x < right &&
          line.y > start &&
          line.y < bottom &&
          compact(line.text).length >= 4 &&
          body.contains(compact(line.text)));
      if (lines.isEmpty) {
        continue;
      }
      final y = lines.map((line) => line.y).reduce((a, b) => a < b ? a : b);
      final distance =
          y < card.key.y ? card.key.y - y : y - (card.key.y + card.key.height);
      if (distance >= -.01 && distance <= .16) {
        result[message.stableId] = card.value;
      }
    }
    return result;
  }
}
