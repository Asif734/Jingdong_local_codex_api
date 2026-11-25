import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> grantRunPermissions(WidgetTester tester) async {
  if (find.text('权限已就绪').evaluate().isNotEmpty) return;
  await tester.tap(find.text('授权所需权限'));
  for (var i = 0; i < 100; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    if (tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Start automation'))
            .onPressed !=
        null) {
      return;
    }
  }
  fail('Mocked run permissions did not enable Start');
}
