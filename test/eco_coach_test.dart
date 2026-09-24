import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/eco_coach.dart';

void main() {
  test('classifies reasons as green, orange, or red', () {
    expect(EcoCoachReason.coasting.severity, EcoCoachReasonSeverity.positive);
    expect(EcoCoachReason.highDemand.severity, EcoCoachReasonSeverity.warning);
    expect(EcoCoachReason.abruptJerk.severity, EcoCoachReasonSeverity.critical);
  });

  EcoCoachSnapshot sample(
    EcoCoachEngine coach, {
    required int milliseconds,
    required double speedKmh,
    double drivePowerKw = 0,
    double pedalFraction = 0,
    bool brakePressed = false,
  }) => coach.observe(
    EcoCoachInput(
      timestamp: Duration(milliseconds: milliseconds),
      speedKmh: speedKmh,
      drivePowerKw: drivePowerKw,
      pedalFraction: pedalFraction,
      brakePressed: brakePressed,
    ),
  );

  test('waits for movement and enough speed samples', () {
    final coach = EcoCoachEngine();

    final moving = sample(coach, milliseconds: 0, speedKmh: 10);

    expect(moving.reason, EcoCoachReason.observing);
    expect(moving.score, isNull);
  });

  test('recognizes coasting without accelerator or brake', () {
    final coach = EcoCoachEngine();
    sample(coach, milliseconds: 0, speedKmh: 30);
    final result = sample(coach, milliseconds: 1000, speedKmh: 30);

    expect(result.reason, EcoCoachReason.coasting);
    expect(result.coasting, isTrue);
    expect(result.score, greaterThanOrEqualTo(90));
  });

  test('strong acceleration lowers score and explains why', () {
    final coach = EcoCoachEngine();
    sample(coach, milliseconds: 0, speedKmh: 10);
    final result = sample(
      coach,
      milliseconds: 1000,
      speedKmh: 25,
      drivePowerKw: 65,
      pedalFraction: 0.8,
    );

    expect(result.accelerationMps2, greaterThan(1));
    expect(
      result.reason,
      anyOf(EcoCoachReason.abruptAcceleration, EcoCoachReason.highDemand),
    );
    expect(result.activeReasons, contains(EcoCoachReason.abruptAcceleration));
    expect(result.activeReasons, contains(EcoCoachReason.highDemand));
    expect(result.score, lessThan(80));
  });

  test('jerk is derived from changes in acceleration', () {
    final coach = EcoCoachEngine();
    sample(coach, milliseconds: 0, speedKmh: 10);
    sample(coach, milliseconds: 1000, speedKmh: 14);
    final result = sample(
      coach,
      milliseconds: 2000,
      speedKmh: 36,
      drivePowerKw: 60,
      pedalFraction: 0.8,
    );

    expect(result.jerkMps3, greaterThan(1));
    expect(result.reason, EcoCoachReason.abruptJerk);
  });

  test('counts accelerate then brake once per brake press', () {
    final coach = EcoCoachEngine();
    sample(coach, milliseconds: 0, speedKmh: 20);
    sample(
      coach,
      milliseconds: 1000,
      speedKmh: 30,
      drivePowerKw: 40,
      pedalFraction: 0.6,
    );
    final braking = sample(
      coach,
      milliseconds: 2500,
      speedKmh: 27,
      drivePowerKw: -8,
      brakePressed: true,
    );
    final held = sample(
      coach,
      milliseconds: 3000,
      speedKmh: 25,
      drivePowerKw: -10,
      brakePressed: true,
    );

    expect(braking.accelerateBrakeCycles, 1);
    expect(braking.reason, EcoCoachReason.accelerateThenBrake);
    expect(held.accelerateBrakeCycles, 1);
  });

  test('negative drive power is identified as regeneration', () {
    final coach = EcoCoachEngine();
    sample(coach, milliseconds: 0, speedKmh: 40);
    final result = sample(
      coach,
      milliseconds: 1000,
      speedKmh: 38,
      drivePowerKw: -7,
    );

    expect(result.reason, EcoCoachReason.regenerating);
  });

  test('updates demand while speed sample remains unchanged', () {
    final coach = EcoCoachEngine();
    sample(coach, milliseconds: 0, speedKmh: 40);
    sample(coach, milliseconds: 1000, speedKmh: 40);

    final result = coach.observe(
      const EcoCoachInput(
        timestamp: Duration(milliseconds: 1100),
        motionTimestamp: Duration(milliseconds: 1000),
        motionSampleChanged: false,
        speedKmh: 40,
        drivePowerKw: 60,
        pedalFraction: 0.8,
        brakePressed: false,
      ),
    );

    expect(result.reason, EcoCoachReason.highDemand);
    expect(result.score, lessThan(100));
  });

  test('keeps multiple recent reasons visible for five seconds', () {
    final coach = EcoCoachEngine();
    sample(coach, milliseconds: 0, speedKmh: 40);
    final coasting = sample(coach, milliseconds: 1000, speedKmh: 40);
    expect(coasting.activeReasons, [EcoCoachReason.coasting]);

    final demanding = coach.observe(
      const EcoCoachInput(
        timestamp: Duration(milliseconds: 1100),
        motionTimestamp: Duration(milliseconds: 1000),
        motionSampleChanged: false,
        speedKmh: 40,
        drivePowerKw: 60,
        pedalFraction: 0.8,
        brakePressed: false,
      ),
    );

    expect(
      demanding.activeReasons,
      containsAll([EcoCoachReason.highDemand, EcoCoachReason.coasting]),
    );
  });

  test('renews only the reason that appears again', () {
    final coach = EcoCoachEngine();
    sample(coach, milliseconds: 0, speedKmh: 40);
    sample(coach, milliseconds: 1000, speedKmh: 40);

    EcoCoachSnapshot demand(int milliseconds) => coach.observe(
      EcoCoachInput(
        timestamp: Duration(milliseconds: milliseconds),
        motionTimestamp: const Duration(milliseconds: 1000),
        motionSampleChanged: false,
        speedKmh: 40,
        drivePowerKw: 60,
        pedalFraction: 0.8,
        brakePressed: false,
      ),
    );

    demand(2500);
    final renewedCoast = coach.observe(
      const EcoCoachInput(
        timestamp: Duration(milliseconds: 2900),
        motionTimestamp: Duration(milliseconds: 1000),
        motionSampleChanged: false,
        speedKmh: 40,
        drivePowerKw: 0,
        pedalFraction: 0,
        brakePressed: false,
      ),
    );
    expect(renewedCoast.activeReasons, contains(EcoCoachReason.coasting));

    final stillVisible = demand(7500);
    expect(stillVisible.activeReasons, contains(EcoCoachReason.coasting));

    final expired = demand(7901);
    expect(expired.activeReasons, isNot(contains(EcoCoachReason.coasting)));
    expect(expired.activeReasons, contains(EcoCoachReason.highDemand));
  });

  test('reason opacity decays across the five second window', () {
    const window = EcoCoachReasonWindow(
      reason: EcoCoachReason.coasting,
      visibleUntil: Duration(seconds: 5),
    );

    expect(window.opacityAt(Duration.zero), 1);
    expect(window.opacityAt(const Duration(milliseconds: 2500)), 0.5);
    expect(window.opacityAt(const Duration(seconds: 5)), 0);
  });

  test('reset clears score and cycle history', () {
    final coach = EcoCoachEngine();
    sample(coach, milliseconds: 0, speedKmh: 20);
    sample(coach, milliseconds: 1000, speedKmh: 30, drivePowerKw: 40);
    sample(coach, milliseconds: 2000, speedKmh: 25, brakePressed: true);

    coach.reset();
    final reset = sample(coach, milliseconds: 3000, speedKmh: 0);
    expect(reset.accelerateBrakeCycles, 0);
    expect(reset.score, isNull);
    expect(reset.activeReasons, [EcoCoachReason.stopped]);
  });
}
