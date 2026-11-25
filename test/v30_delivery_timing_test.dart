import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/runtime/delivery_timing.dart';

void main() {
  test(
      'stale OCR clock cannot masquerade as observed service or verified platform SLA',
      () {
    final click = DateTime.utc(2026, 11, 4, 8, 36, 59);
    final fields = formalReplyTiming({
      'customerMessageAt': '2026-11-04T08:35:29Z',
      'firstObservedAt': '2026-11-04T08:36:58Z',
      'batchEndMessageId': 'latest'
    }, confirmedAt: click.add(const Duration(seconds: 1)), clickedAt: click);
    expect(fields['firstObservedToClickMs'], 1000);
    expect(fields['senderToClickEstimateMs'], 90000);
    expect(fields['senderClockVerified'], isFalse);
    expect(fields['platformSlaVerified'], isFalse);
    expect(fields.containsKey('endToEndMs'), isFalse);
    expect(fields['businessResponseSent'], isTrue);
    expect(fields['caseResolved'], isNull);
  });
  test('missing or impossible timestamps remain unknown', () {
    final at = DateTime.utc(2026, 11, 4);
    final fields = formalReplyTiming({
      'firstObservedAt': at.add(const Duration(seconds: 5)).toIso8601String()
    }, confirmedAt: at);
    expect(fields['firstObservedToClickMs'], isNull);
    expect(fields['senderToClickEstimateMs'], isNull);
    expect(fields['clickTimeSource'], 'confirmation_fallback');
    expect(fields['sendClickedAt'], isNull);
  });
}
