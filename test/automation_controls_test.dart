import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jd_automation/runtime/automation_settings.dart';
import 'package:jd_automation/ui/automation_controls.dart';

void main() {
  testWidgets('defaults, range validation and running lock', (tester) async {
    AutomationSettings? changed;
    bool? valid;
    Future<void> show(bool locked) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: AutomationControls(
            settings: const AutomationSettings(),
            locked: locked,
            onChanged: (value) => changed = value,
            onValidityChanged: (value) => valid = value,
          )),
        ));
    await show(false);
    expect(find.text('50'), findsOneWidget);
    expect(find.byKey(const ValueKey('transfer-request-count')), findsNothing);
    expect(find.text('要求转接（次）'), findsNothing);
    final holding = find.byKey(const ValueKey('holding-seconds'));
    await tester.enterText(holding, '19');
    await tester.pump();
    expect(valid, false);
    expect(changed, isNull);
    await tester.enterText(holding, '500');
    await tester.pump();
    expect(valid, true);
    expect(changed!.holdingResponseSeconds, 500);
    await show(true);
    expect(tester.widget<TextField>(holding).enabled, false);
  });
}
