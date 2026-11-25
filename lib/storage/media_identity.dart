import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../domain/customer_message_time.dart';
import 'conversation_file_store.dart';

class MediaIdentity {
  const MediaIdentity(this.id, this.reused, {this.clockRefined = false});
  final String id;
  final bool reused;
  final bool clockRefined;
}

/// Media content locates an asset. A complete customer sender second owns the
/// business message; a receipt can only continue an explicitly held owner.
class MediaIdentityResolver {
  MediaIdentityResolver(this.store);
  final ConversationFileStore store;

  Future<MediaIdentity> resolve({
    required String customer,
    required String kind,
    required String digest,
    required DateTime observedAt,
    DateTime? sentAt,
    String? turnKey,
    String? mediaReceiptId,
    String? anchoredMessageId,
  }) async {
    final timeKey = sentAt == null
        ? null
        : CustomerMessageTime.incomingId(customer, sentAt);
    final document = await store.read(customer);
    final incoming = (document?['messages'] as List? ?? const [])
        .whereType<Map>()
        .where((m) => m['direction'] == 'incoming')
        .toList();
    final held = incoming.where((m) {
      if (timeKey != null) {
        final previous = ConversationFileStore.incomingTimeKey(customer, m);
        if (previous != null && previous != timeKey) return false;
      }
      return (anchoredMessageId != null &&
              ConversationFileStore.messageAliases(m)
                  .contains(anchoredMessageId)) ||
          (mediaReceiptId != null &&
              (m['media_receipt_id'] == mediaReceiptId ||
                  (m['media_receipt_aliases'] as List? ?? const [])
                      .contains(mediaReceiptId)));
    }).toList();
    // Keep an already held legacy owner while filling its previously absent
    // clock. No body, hash or proximity window may select this owner.
    if (held.length == 1) {
      final row = held.single;
      final missing =
          ConversationFileStore.incomingTimeKey(customer, row) == null;
      final id = sentAt == null
          ? row['id']! as String
          : await store.bindIncomingMessageTime(
                  customer, row['id']! as String, sentAt) ??
              row['id']! as String;
      return MediaIdentity(id, true, clockRefined: missing && sentAt != null);
    }
    if (sentAt != null) {
      final existing = await store.incomingMessageIdAtTime(customer, sentAt);
      return MediaIdentity(existing ?? timeKey!, existing != null);
    }
    // This is an observation locator only. The admission layer retains the
    // source frame and does not create business work without a sender second.
    final source = turnKey ?? observedAt.toUtc().toIso8601String();
    return MediaIdentity(
        'visible-$kind:$digest:observed:'
        '${sha256.convert(utf8.encode(source)).toString().substring(0, 16)}',
        false);
  }
}
