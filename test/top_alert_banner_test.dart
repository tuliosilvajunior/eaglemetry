import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/design_system/design_system.dart';

void main() {
  testWidgets('top alert exposes the error and dismiss action', (tester) async {
    var dismissed = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: AutomotiveTheme.dark(),
        home: Scaffold(
          body: TopAlertBanner(
            title: 'UPDATE FAILED',
            message: 'Downloaded APK signing information is unavailable',
            dismissLabel: 'DISMISS',
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );

    expect(find.text('UPDATE FAILED'), findsOneWidget);
    expect(
      find.text('Downloaded APK signing information is unavailable'),
      findsOneWidget,
    );

    final dismissButton = tester.getSize(
      find.widgetWithText(TextButton, 'DISMISS'),
    );
    expect(dismissButton.height, greaterThanOrEqualTo(64));
    await tester.tap(find.text('DISMISS'));
    expect(dismissed, isTrue);
  });
}
