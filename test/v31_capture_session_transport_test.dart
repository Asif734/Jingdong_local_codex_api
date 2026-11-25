import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final session in <String?>['run-one', null]) {
    test('viewport capture forwards optional session nonce: $session',
        () async {
      final channel =
          MethodChannel('jd.v31.evidence-transport.${session ?? 'legacy'}');
      final capturedAt = DateTime.utc(2026, 11, 4, 10);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'captureViewportEvidence');
        final args = call.arguments as Map;
        expect(args['expectedCustomer'], 'jd_exactI1l');
        expect(args['directory'], '/controlled/evidence');
        expect(args.containsKey('automationSessionId'), session != null);
        if (session != null) expect(args['automationSessionId'], session);
        return {
          'evidenceId': 'native-immutable-frame',
          'customer': 'jd_exactI1l',
          'imagePath': '/controlled/evidence/frame.png',
          'manifestPath': '/controlled/evidence/frame.json',
          'capturedAtMs': capturedAt.millisecondsSinceEpoch,
          if (session != null) 'automationSessionId': session,
        };
      });
      final adapter = MacOSCaptureAdapter(channel: channel);
      addTearDown(adapter.close);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final evidence = await adapter.captureViewportEvidence(
          expectedCustomer: 'jd_exactI1l',
          directory: '/controlled/evidence',
          automationSessionId: session);

      expect(evidence.metadata['automationSessionId'], session);
      expect(evidence.customer, 'jd_exactI1l');
      expect(evidence.capturedAt, capturedAt,
          reason: 'A native capture keeps its actual capture time.');
    });
  }
}
