/// The shop's message identity contract: one incoming message per customer
/// per complete sender calendar second. Neither OCR text nor media assets,
/// screenshot geometry, capture order or response-cycle ordinals enter it.
class CustomerMessageTime {
  static DateTime second(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
      (value.toUtc().millisecondsSinceEpoch ~/ 1000) * 1000,
      isUtc: true);

  static String incomingId(String customer, DateTime senderAt) {
    if (customer.trim().isEmpty) {
      throw ArgumentError.value(customer, 'customer');
    }
    final stamp = second(senderAt).toIso8601String().replaceFirst('.000Z', 'Z');
    return 'incoming-time:${Uri.encodeComponent(customer)}:$stamp';
  }

  static String occurrenceKey(String customer, DateTime senderAt) =>
      incomingId(customer, senderAt);

  static bool isTimeId(String value) => value.startsWith('incoming-time:');

  static bool sameSecond(DateTime a, DateTime b) => second(a) == second(b);

  static String? forMessage(String customer, Map message) {
    if (message['direction'] != 'incoming') return null;
    final at = DateTime.tryParse(message['sent_at']?.toString() ?? '');
    return at == null ? null : incomingId(customer, at);
  }
}
