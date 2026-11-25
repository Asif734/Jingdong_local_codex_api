import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// Atomic local metadata read by native code immediately before insertion and
/// click. This guards media-state changes while a send owns the native queue.
class DeliveryContextGuard {
  static File file(Directory root, String customer) => File(
      '${root.path}/delivery_contexts/${sha256.convert(utf8.encode(customer))}.json');
  static Future<void> publish(
      Directory root, String customer, int revision) async {
    final target = file(root, customer);
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(
        jsonEncode({'customer': customer, 'revision': revision}),
        flush: true);
    await temp.rename(target.path);
  }

  static File scopedFile(Directory root, String customer, String attemptId) =>
      file(root, '$customer\u001f$attemptId');

  /// The native reader still checks the exact customer. The file belongs to
  /// one attempt, so an unrelated attachment cannot invalidate its insertion.
  static Future<void> publishScoped(
      Directory root, String customer, String attemptId, int revision) async {
    final target = scopedFile(root, customer, attemptId);
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(
        jsonEncode({'customer': customer, 'revision': revision}),
        flush: true);
    await temp.rename(target.path);
  }
}
