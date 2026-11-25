import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/capture_activation_context.dart';

void main() {
  test('a cold cache retains a frozen AX arrival after holding clears red', () {
    final snapshot = <String, Object?>{
      'context': null,
      'liveArrival': 'arrival:red-transition:current-run:1',
      'recoveryActive': false,
    };
    final context = captureContextFromFrozenSnapshot(snapshot)!;
    expect(context['observedArrival'], isNull);
    expect(context['frontier'], isNull);
    expect(context['cycle'], isNull);
    expect(context['durable'], isFalse);
    expect(context['acquisitions'], isEmpty);
    expect(snapshot['liveArrival'] != context['observedArrival'], isTrue,
        reason:
            'The original frame still enters live discovery, not baseline.');
    expect(
        captureContextFromFrozenSnapshot({
          'context': null,
          'liveArrival': null,
          'recoveryActive': true,
        }),
        isNotNull);
  });

  test('no current or later signal is invented for an observational frame', () {
    expect(captureContextFromFrozenSnapshot({'context': null}), isNull);
    expect(
        captureContextFromFrozenSnapshot({
          'context': null,
          'recoveryActive': false,
          'liveArrival': '',
        }),
        isNull);
    final original = <String, Object?>{
      'frontier': 'frozen-original-frontier',
      'observedArrival': 'original-arrival',
    };
    final context = captureContextFromFrozenSnapshot({
      'context': original,
      'liveArrival': 'original-arrival',
    })!;
    original['frontier'] = 'later-frontier';
    expect(context['frontier'], 'frozen-original-frontier');
  });
}
