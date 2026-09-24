import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

Future<void> _loadInter() async {
  final loader = FontLoader(AppFonts.family);
  for (final asset in [
    'packages/capy_ui/assets/fonts/Inter-Regular.ttf',
    'packages/capy_ui/assets/fonts/Inter-Medium.ttf',
    'packages/capy_ui/assets/fonts/Inter-SemiBold.ttf',
    'packages/capy_ui/assets/fonts/Inter-Bold.ttf',
    'packages/capy_ui/assets/fonts/Inter-ExtraBold.ttf',
  ]) {
    loader.addFont(rootBundle.load(asset));
  }
  await loader.load();
}

void main() {
  setUpAll(_loadInter);

  testWidgets('keeps a missing value visible beside a long unit', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 72,
              child: StatColumn(value: '--', unit: 'km/kWh', caption: 'Avg.'),
            ),
          ),
        ),
      ),
    );

    final value = find.text('--');
    expect(value, findsOneWidget);
    expect(tester.getSize(value).width, greaterThanOrEqualTo(16));
    expect(
      tester.renderObject<RenderParagraph>(value).didExceedMaxLines,
      false,
    );
  });
}
