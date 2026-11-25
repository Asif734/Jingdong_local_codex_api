import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import '../domain/capture_models.dart';
import 'customer_media_inventory.dart';

/// Reuses immutable video/audio artifacts, never replies or customer identity.
class ProcessedVideoStore {
  ProcessedVideoStore(this.root);
  final Directory root;
  final Map<String, Future<CapturedMessage>> _running = {};
  Future<CapturedMessage> getOrCreate(
      String customer, String digest, Future<CapturedMessage> Function() create,
      {void Function()? onReuse, String? cacheContract}) {
    final key =
        '${sha256.convert(utf8.encode(customer))}:$digest:$cacheContract';
    final running = _running[key];
    if (running != null) {
      onReuse?.call();
      return running;
    }
    final future =
        _loadOrCreate(customer, digest, create, onReuse, cacheContract);
    _running[key] = future;
    // Preserve the original future, including its error, for every waiter.
    future.then((_) {
      _running.remove(key);
    }, onError: (Object _, StackTrace __) {
      _running.remove(key);
    });
    return future;
  }

  Future<CapturedMessage> _loadOrCreate(
      String customer,
      String digest,
      Future<CapturedMessage> Function() create,
      void Function()? onReuse,
      String? cacheContract) async {
    final file = File(
        '${root.path}/${sha256.convert(utf8.encode(customer))}/$digest.json');
    try {
      final value =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (value['customer'] == customer &&
          value['digest'] == digest &&
          value['cacheContract'] == cacheContract) {
        final message = CapturedMessage.fromMap(value['message'] as Map);
        if (message.media.isNotEmpty &&
            await Future.wait(message.media.map((m) =>
                    CustomerMediaInventory.localFileReadableNonempty(m.path)))
                .then((all) => all.every((v) => v))) {
          onReuse?.call();
          return message;
        }
      }
    } on FileSystemException catch (_) {
    } on FormatException catch (_) {
    } on TypeError catch (_) {}
    final message = await create();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.partial');
    await temp.writeAsString(
        jsonEncode({
          'customer': customer,
          'digest': digest,
          'cacheContract': cacheContract,
          'message': {
            'stableId': message.stableId,
            'direction': message.direction,
            'body': message.body,
            'axPath': message.axPath,
            'media': [
              for (final m in message.media)
                {
                  'type': m.type,
                  'path': m.path,
                  'mimeType': m.mimeType,
                  'originalName': m.originalName,
                  'captureSource': m.captureSource,
                  'isPartial': m.isPartial,
                  'description': m.description,
                  'visualFingerprint': m.visualFingerprint
                }
            ]
          }
        }),
        flush: true);
    await temp.rename(file.path);
    return message;
  }
}
