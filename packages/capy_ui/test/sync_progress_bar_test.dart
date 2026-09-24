import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  Widget buildFrame(Widget child) {
    return MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(child: SizedBox(width: 300, child: child)),
      ),
    );
  }

  group('SyncProgressBar', () {
    testWidgets('renders 100% when up to date', (tester) async {
      await tester.pumpWidget(
        buildFrame(
          const SyncProgressBar(
            progress: SyncProgressData(totalCount: 50, dirtyCount: 0),
            label: 'Nuvem',
            statusText: '100% em dia',
          ),
        ),
      );

      expect(find.text('Nuvem'), findsOneWidget);
      expect(find.text('100% em dia'), findsOneWidget);
    });

    testWidgets('renders pending status and detailText', (tester) async {
      await tester.pumpWidget(
        buildFrame(
          const SyncProgressBar(
            progress: SyncProgressData(totalCount: 100, dirtyCount: 20),
            label: 'Progresso',
            statusText: '80% (20 pendentes)',
            detailText: '80 de 100 registros na nuvem',
          ),
        ),
      );

      expect(find.text('Progresso'), findsOneWidget);
      expect(find.text('80% (20 pendentes)'), findsOneWidget);
      expect(find.text('80 de 100 registros na nuvem'), findsOneWidget);
    });

    testWidgets('fill moves over AppMotion.slow', (tester) async {
      await tester.pumpWidget(
        buildFrame(
          const SyncProgressBar(
            progress: SyncProgressData(totalCount: 100, dirtyCount: 20),
          ),
        ),
      );

      final fill = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      expect(fill.duration, AppMotion.slow);
      expect(fill.curve, AppMotion.curve);
    });

    testWidgets('fill jumps to the reading under reduced motion', (
      tester,
    ) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: buildFrame(
            const SyncProgressBar(
              progress: SyncProgressData(totalCount: 100, dirtyCount: 20),
            ),
          ),
        ),
      );

      final fill = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      expect(fill.duration, Duration.zero);
    });
  });
}
