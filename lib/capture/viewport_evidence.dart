import 'dart:convert';
import 'dart:io';

/// Identity and coordinates belong to these immutable pixels, never the live UI.
class ViewportEvidence {
  const ViewportEvidence(this.metadata);
  factory ViewportEvidence.fromMap(Map value) =>
      ViewportEvidence(value.map((key, value) => MapEntry('$key', value)));
  factory ViewportEvidence.fromJson(String value) =>
      ViewportEvidence.fromMap(jsonDecode(value) as Map);
  final Map<String, Object?> metadata;
  String get id => metadata['evidenceId']! as String;
  String get customer => metadata['customer']! as String;
  String get manifestPath => metadata['manifestPath']! as String;
  String get imagePath => metadata['imagePath']! as String;
  DateTime get capturedAt => DateTime.fromMillisecondsSinceEpoch(
      (metadata['capturedAtMs']! as num).toInt(),
      isUtc: true);
  Map<String, Object?>? get pinnedMedia => metadata['pinnedMedia'] is Map
      ? Map<String, Object?>.from(metadata['pinnedMedia']! as Map)
      : null;
  ViewportEvidence withPinnedMedia(Map<String, Object?> media) =>
      ViewportEvidence({...metadata, 'pinnedMedia': media});
  Future<bool> filesExist() async =>
      await File(imagePath).exists() && await File(manifestPath).exists();
  String toJson() => jsonEncode(metadata);
}
