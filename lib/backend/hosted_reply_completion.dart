/// The immutable local receipt handed directly from a completed API job to the
/// guarded send path. Internal history never becomes part of the API request.
class HostedReplyCompletion {
  HostedReplyCompletion({
    required this.customer,
    required Map<String, dynamic> source,
    required Map<String, dynamic> rawResult,
    required this.receivedAt,
    required this.expectedSessionId,
  })  : source = _freeze(source) as Map<String, dynamic>,
        rawResult = _freeze(rawResult) as Map<String, dynamic>;

  final String customer;
  final Map<String, dynamic> source;
  final Map<String, dynamic> rawResult;
  final DateTime receivedAt;
  final String? expectedSessionId;
  String get sourceMessageId => source['id'] as String;
  String get jobId => rawResult['jobId'] as String;

  static Object? _freeze(Object? value) {
    if (value is Map) {
      return Map<String, dynamic>.unmodifiable({
        for (final entry in value.entries)
          entry.key as String: _freeze(entry.value),
      });
    }
    if (value is List) return List<dynamic>.unmodifiable(value.map(_freeze));
    return value;
  }
}
