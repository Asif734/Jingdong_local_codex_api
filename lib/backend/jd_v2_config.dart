import 'dart:convert';
import 'dart:io';

/// Installation credentials live outside the source tree and application bundle.
class JdV2Config {
  const JdV2Config(
      {required this.baseUri,
      required this.apiKey,
      this.storeId = 'jd-grozziie'});
  final Uri baseUri;
  final String apiKey;
  final String storeId;

  static Future<JdV2Config> load(
      {File? file, Map<String, String>? environment}) async {
    final env = environment ?? Platform.environment;
    final path = file ??
        File(
            '${env['HOME']}/Library/Application Support/JD Automation/hosted-reply.json');
    Map raw = const {};
    if (await path.exists()) {
      try {
        raw = jsonDecode(await path.readAsString()) as Map;
      } catch (_) {
        throw StateError('JD API private configuration is invalid.');
      }
    }
    final uri = Uri.tryParse(
        env['JD_REPLY_API_URL'] ?? raw['baseUrl']?.toString() ?? '');
    final key = env['JD_REPLY_API_KEY'] ?? raw['apiKey']?.toString() ?? '';
    final store = raw['storeId']?.toString() ?? 'jd-grozziie';
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        key.trim().isEmpty ||
        key.contains(RegExp(r'[\r\n]')) ||
        store != 'jd-grozziie') {
      throw StateError('JD API private configuration is missing or invalid.');
    }
    return JdV2Config(baseUri: uri, apiKey: key, storeId: store);
  }
}
