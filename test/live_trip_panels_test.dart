import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/eco_coach.dart';
import 'package:capy_energy/screens/trips/live_trip_panels.dart';

const _snapshot = EcoCoachSnapshot(
  score: 75,
  reason: EcoCoachReason.highDemand,
  observedAt: Duration.zero,
  reasonWindows: [],
  accelerationMps2: 0.4,
  jerkMps3: 0.2,
  demandFraction: 0.6,
  coasting: false,
  accelerateBrakeCycles: 0,
);

LiveEcoCoachReason _reason(
  EcoCoachReason reason,
  String label, {
  Duration visibleUntil = const Duration(seconds: 5),
}) => LiveEcoCoachReason(
  window: EcoCoachReasonWindow(reason: reason, visibleUntil: visibleUntil),
  label: label,
);

void main() {
  testWidgets('eco reasons stay below the score in severity and name order', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveEcoCoachPanel(
            snapshot: _snapshot,
            title: 'Eco Coach',
            reasons: [
              _reason(EcoCoachReason.abruptJerk, 'Red'),
              _reason(EcoCoachReason.efficientDemand, 'Zeta'),
              _reason(EcoCoachReason.highDemand, 'Orange'),
              _reason(EcoCoachReason.coasting, 'Alpha'),
            ],
            timestamp: Duration.zero,
            observingLabel: 'Observing',
            accelerationLabel: 'Acceleration',
            jerkLabel: 'Jerk',
            cyclesLabel: 'Cycles',
            betaLabel: 'Beta',
          ),
        ),
      ),
    );

    final scoreY = tester.getTopLeft(find.text('75')).dy;
    final alphaY = tester.getTopLeft(find.text('Alpha')).dy;
    final zetaY = tester.getTopLeft(find.text('Zeta')).dy;
    final orangeY = tester.getTopLeft(find.text('Orange')).dy;
    final redY = tester.getTopLeft(find.text('Red')).dy;

    expect(scoreY, lessThan(alphaY));
    expect(alphaY, lessThan(zetaY));
    expect(zetaY, lessThan(orangeY));
    expect(orangeY, lessThan(redY));
    expect(tester.takeException(), isNull);
  });

  testWidgets('eco reason opacity follows its remaining lifetime', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveEcoCoachPanel(
            snapshot: _snapshot,
            title: 'Eco Coach',
            reasons: [
              _reason(
                EcoCoachReason.coasting,
                'Fading',
                visibleUntil: const Duration(milliseconds: 2500),
              ),
            ],
            timestamp: Duration.zero,
            observingLabel: 'Observing',
            accelerationLabel: 'Acceleration',
            jerkLabel: 'Jerk',
            cyclesLabel: 'Cycles',
            betaLabel: 'Beta',
          ),
        ),
      ),
    );

    final fade = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('eco_reason_coasting')),
    );
    expect(fade.opacity, 0.5);
  });
}
