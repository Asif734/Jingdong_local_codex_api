import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/capture/ocr_capture_extractor.dart';
import 'package:jd_automation/platform/macos_capture_adapter.dart';

void main() {
  const extractor = OcrCaptureExtractor();
  const card = OcrVisualRegion(
      x: .27582496404647827,
      y: .31816166639328003,
      width: .1045188307762146,
      height: .10469281673431396,
      confidence: 1);
  OcrInspection frame(String clock, DateTime at, {bool body = false}) =>
      OcrInspection(
          image: Uint8List(0),
          imageWidth: 2880,
          imageHeight: 1626,
          windowTitle: 'saved calendar fixture',
          recognizedText: '',
          activeCustomerId: 'jd_calendar_fixture',
          windowId: 7,
          capturedAt: at,
          chatTop: .20418204182041821,
          chatBottom: .8044280442804428,
          chatLeft: .24027777777777778,
          chatRight: .7479166666666667,
          observations: [
            OcrObservation(
                text: 'jd_calendar_fixture $clock',
                confidence: 1,
                x: .2732558142525926,
                y: .24164524438779988,
                width: .2,
                height: .015427326071013159),
            if (body)
              const OcrObservation(
                  text: 'Historical customer question',
                  confidence: 1,
                  x: .28,
                  y: .28,
                  width: .2,
                  height: .018)
          ]);
  DateTime? media(String clock, DateTime at) =>
      extractor.mediaClockForRegion(frame(clock, at), card).sentAt;
  final nov4 = DateTime.utc(2026, 11, 4, 9, 58, 14);
  test('recorded MM-DD header is yesterday, not capture day', () {
    expect(media('11-03 13:16:00', nov4), DateTime.utc(2026, 11, 3, 5, 16));
    final text = extractor.analyze(frame('11-03 13:16:00', nov4, body: true));
    expect(text.latestIncomingSentAt, DateTime.utc(2026, 11, 3, 5, 16));
    expect(
        text.capture!.messages.single.sentAt, DateTime.utc(2026, 11, 3, 5, 16));
  });
  test('explicit YYYY dates and alternate separators retain date', () {
    for (final value in [
      '2026-11-03 13:16:00',
      '2026/11/03 13:16:00',
      '2026.11.03 13：16：00'
    ]) {
      expect(media(value, nov4), DateTime.utc(2026, 11, 3, 5, 16));
    }
    expect(media('11/03 13:16', nov4), DateTime.utc(2026, 11, 3, 5, 16));
  });
  test('clock-only labels can cross JD midnight without using the Mac date',
      () {
    final midnight = DateTime.utc(2026, 11, 3, 16, 0, 30);
    expect(media('23:59:50', midnight), DateTime.utc(2026, 11, 3, 15, 59, 50));
    expect(media('11-03 23:59:50', midnight),
        DateTime.utc(2026, 11, 3, 15, 59, 50));
  });
  test('yearless December history on January 1 belongs to previous year', () {
    final jan1 = DateTime.utc(2025, 12, 31, 16, 1);
    expect(media('12-31 23:59:00', jan1), DateTime.utc(2025, 12, 31, 15, 59));
    expect(
        media('2025-12-31 23:59:00', jan1), DateTime.utc(2025, 12, 31, 15, 59));
  });
  test(
      'explicit future date is unknown, not silently rolled to yesterday or last year',
      () {
    expect(media('11-05 13:16:00', nov4), isNull);
    expect(media('2027-11-03 13:16:00', nov4), isNull);
    expect(media('01-02 00:00:00', DateTime.utc(2025, 12, 31, 16, 1)), isNull);
  });
  test('invalid calendar values are not normalized into another day', () {
    expect(media('2026-02-29 13:16:00', nov4), isNull);
    expect(media('11-32 13:16:00', nov4), isNull);
    expect(media('13-03 13:16:00', nov4), isNull);
    expect(
        media('2024-02-29 13:16:00', nov4), DateTime.utc(2024, 2, 29, 5, 16));
  });
  test('all active opener success branches use the focus contract', () async {
    final source =
        await File('macos/Runner/AccessibilityBridge.swift').readAsString();
    final openers = source.substring(
        source.indexOf('  func openConversationRow('),
        source.indexOf('  func listActiveTransferAccounts('));
    expect(RegExp(r'finish\(\["opened"').allMatches(openers), isEmpty);
    expect(
        RegExp(r'finishOpened\(\["opened"').allMatches(openers), hasLength(7));
    expect(openers, contains('openedReceptionFocus'));
  });
}
