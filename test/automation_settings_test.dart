import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/runtime/automation_settings.dart';
import 'package:jd_automation/storage/capture_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('safe defaults and bounded persisted values', () {
    expect(const AutomationSettings().holdingResponseSeconds, 50);
    final settings = AutomationSettings.fromJson({
      'holdingResponseSeconds': 900,
      'transferRequestCount': 1,
      'secret': 'must not persist',
    });
    expect(settings.holdingResponseSeconds, 500);
    expect(settings.toJson().containsKey('transferRequestCount'), isFalse);
    expect(
        AutomationSettings.fromJson({'holdingResponseSeconds': 'bad'})
            .holdingResponseSeconds,
        50);
    expect(settings.toJson().keys, unorderedEquals(['holdingResponseSeconds']));
  });
  test(
      'settings persist only safe runtime parameters and corrupt files recover',
      () async {
    final root = await Directory.systemTemp.createTemp('jd_settings_');
    addTearDown(() => root.delete(recursive: true));
    final store = AutomationSettingsStore(storageRoot: root);
    const settings = AutomationSettings(
        holdingResponseSeconds: 123, transferRequestCount: 7);
    await store.save(settings);
    final reloaded = await AutomationSettingsStore(storageRoot: root).load();
    expect(reloaded.holdingResponseSeconds, 123);
    final file = File('${root.path}/automation_settings.json');
    expect((jsonDecode(await file.readAsString()) as Map).length, 1);
    await file.writeAsString('{broken');
    expect((await store.load()).holdingResponseSeconds, 50);
  });
  test('legacy request observations do not trigger local handoff', () async {
    final root = await Directory.systemTemp.createTemp('jd_gate_');
    final db = CaptureDatabase(
        storageRoot: root,
        automationSettings: const AutomationSettings(
            holdingResponseSeconds: 100, transferRequestCount: 4));
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    expect(db.holdingDelay, const Duration(seconds: 100));
    final at = DateTime.now();
    Future<bool> record(String id, int seconds,
            {List<String> aliases = const []}) =>
        db.recordHumanTransferRequest(
            userId: 'buyer',
            messageId: id,
            messageAliases: aliases,
            requestedAt: at.add(Duration(seconds: seconds)));
    expect(await record('a', 0), isFalse);
    expect(await record('canonical-a', 1, aliases: ['a']), isFalse);
    expect(await record('canonical-a', 1), isFalse);
    expect(await record('b', 2), isFalse);
    expect(await record('c', 3), isFalse);
    expect(await record('d', 4), isFalse);
    expect(await record('d', 5), isFalse);
    expect(await record('e', 6), isFalse);
    expect(await record('f', 607), isFalse);
    expect(await record('g', 608), isFalse);
    expect(await record('h', 609), isFalse);
    expect(await record('i', 610), isFalse);
  });
  test('first canonical request retains its aliases across restart', () async {
    final root = await Directory.systemTemp.createTemp('jd_alias_gate_');
    var db = CaptureDatabase(storageRoot: root);
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final at = DateTime.now();
    expect(
        await db.recordHumanTransferRequest(
            userId: 'buyer',
            messageId: 'canonical',
            messageAliases: ['old-observation'],
            requestedAt: at),
        isFalse);
    await db.close();
    db = CaptureDatabase(storageRoot: root);
    expect(
        await db.recordHumanTransferRequest(
            userId: 'buyer',
            messageId: 'old-observation',
            requestedAt: at.add(const Duration(seconds: 1))),
        isFalse);
    for (var index = 2; index <= 3; index++) {
      expect(
          await db.recordHumanTransferRequest(
              userId: 'buyer',
              messageId: 'request-$index',
              requestedAt: at.add(Duration(seconds: index))),
          isFalse);
    }
    expect(
        await db.recordHumanTransferRequest(
            userId: 'buyer',
            messageId: 'request-4',
            requestedAt: at.add(const Duration(seconds: 4))),
        isFalse);
  });

  for (final seconds in [20, 50, 500]) {
    test('response deadline consumes configured $seconds second window',
        () async {
      final root = await Directory.systemTemp.createTemp('jd_timing_');
      final db = CaptureDatabase(
          storageRoot: root,
          automationSettings:
              AutomationSettings(holdingResponseSeconds: seconds));
      addTearDown(() async {
        await db.close();
        await root.delete(recursive: true);
      });
      final at = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().millisecondsSinceEpoch);
      await db.observePlatformResponse('buyer', red: true, observedAt: at);
      final job = (await db.slaFallbackJob('buyer'))!;
      expect(job.dueAt, at.add(Duration(seconds: seconds)));
      await db.observePlatformResponse('buyer',
          red: true,
          observedAt: at.add(const Duration(seconds: 3)),
          ageSeconds: 3);
      expect((await db.slaFallbackJob('buyer'))!.dueAt, job.dueAt);
    });
  }

  test('legacy threshold argument cannot authorize a handoff', () async {
    final root = await Directory.systemTemp.createTemp('jd_max_gate_');
    final db = CaptureDatabase(
        storageRoot: root,
        automationSettings: const AutomationSettings(transferRequestCount: 20));
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    final at = DateTime.now();
    for (var count = 1; count <= 20; count++) {
      expect(
          await db.recordHumanTransferRequest(
              userId: 'buyer',
              messageId: '$count',
              requestedAt: at.add(Duration(seconds: count))),
          isFalse);
    }
  });
}
