import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Non-sensitive runtime preferences. Apply a snapshot before starting a run.
class AutomationSettings {
  const AutomationSettings({
    this.holdingResponseSeconds = 50,
    // Ignored legacy constructor argument; transfer is now decided by API action.
    int? transferRequestCount,
  }) : assert(holdingResponseSeconds >= 20 && holdingResponseSeconds <= 500);

  static const minHoldingResponseSeconds = 20;
  static const maxHoldingResponseSeconds = 500;
  final int holdingResponseSeconds;
  Duration get holdingDelay => Duration(seconds: holdingResponseSeconds);

  factory AutomationSettings.fromJson(Map<String, dynamic> json) {
    int bounded(String key, int fallback, int min, int max) {
      final value = json[key];
      return value is int ? value.clamp(min, max) : fallback;
    }

    return AutomationSettings(
      holdingResponseSeconds: bounded('holdingResponseSeconds', 50, 20, 500),
    );
  }

  void validate() {
    if (holdingResponseSeconds < 20 || holdingResponseSeconds > 500) {
      throw ArgumentError('Automation settings are outside supported limits.');
    }
  }

  Map<String, dynamic> toJson() => {
        'holdingResponseSeconds': holdingResponseSeconds,
      };
}

class AutomationSettingsStore {
  AutomationSettingsStore({Directory? storageRoot})
      : _storageRoot = storageRoot;
  final Directory? _storageRoot;

  Future<File> get _file async {
    final root = _storageRoot ?? await getApplicationSupportDirectory();
    return File(p.join(root.path, 'automation_settings.json'));
  }

  Future<AutomationSettings> load() async {
    try {
      final decoded = jsonDecode(await (await _file).readAsString());
      if (decoded is Map<String, dynamic>) {
        return AutomationSettings.fromJson(decoded);
      }
    } on FileSystemException {
      // A fresh installation has no preferences yet.
    } on FormatException {
      // A partial or manually edited file must not block startup.
    }
    return const AutomationSettings();
  }

  Future<void> save(AutomationSettings settings) async {
    settings.validate();
    final file = await _file;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(settings.toJson()), flush: true);
    await temporary.rename(file.path);
  }
}
