import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

const params = VehicleParams();

/// A speed series sampled at [hz], from a function of time.
List<SpeedSample> series(
  double seconds,
  double hz,
  double Function(double t) speedAt,
) {
  final samples = <SpeedSample>[];
  final count = (seconds * hz).round();
  for (var i = 0; i <= count; i++) {
    final t = i / hz;
    samples.add(SpeedSample(t, speedAt(t)));
  }
  return samples;
}

void main() {
  group('computeBreakdown', () {
    test('level cruise spends on rolling and aero, and nothing else', () {
      final breakdown = computeBreakdown(
        const PhysicsSample(
          speedMps: 25.0,
          accelerationMps2: 0.0,
          inclinePercent: 0.0,
          measuredDriveW: 8000.0,
          measuredPackW: 8400.0,
        ),
        params,
      );

      expect(breakdown.gradeW, 0.0);
      expect(breakdown.kineticW, 0.0);
      expect(breakdown.rollingW, closeTo(4180.7, 1.0));
      expect(breakdown.aeroW, closeTo(6750.0, 1.0));
      expect(breakdown.modelRoadW, closeTo(10930.7, 2.0));

      // Aero must dominate rolling at motorway speed. If it ever does not, the
      // drag area seed is wrong by more than the model can absorb.
      expect(breakdown.aeroW, greaterThan(breakdown.rollingW));

      expect(breakdown.totalAuxW, closeTo(400.0, 0.01));
      expect(breakdown.unattributedAuxW, closeTo(400.0, 0.01));
      expect(breakdown.regenRecoveredW, 0.0);
    });

    test('a constant climb adds the grade term and only that', () {
      const level = PhysicsSample(
        speedMps: 20.0,
        accelerationMps2: 0.0,
        inclinePercent: 0.0,
        measuredDriveW: 6000.0,
      );
      const climb = PhysicsSample(
        speedMps: 20.0,
        accelerationMps2: 0.0,
        inclinePercent: 5.0,
        measuredDriveW: 6000.0,
      );

      final flat = computeBreakdown(level, params);
      final uphill = computeBreakdown(climb, params);

      // m g sin(atan(0.05)) v = 1550 * 9.80665 * 0.049938 * 20
      expect(uphill.gradeW, closeTo(15177.0, 5.0));
      expect(flat.gradeW, 0.0);

      // Rolling falls very slightly, by cos theta. Aero does not move at all.
      expect(uphill.aeroW, closeTo(flat.aeroW, 1e-9));
      expect(uphill.rollingW, lessThan(flat.rollingW));
      expect(uphill.rollingW, closeTo(flat.rollingW * 0.99875, 1.0));

      // The climb costs more than the model says it costs, at the battery.
      expect(uphill.residualRoadW!, lessThan(flat.residualRoadW!));
    });

    test('descending returns power, and the sign survives the efficiency', () {
      final breakdown = computeBreakdown(
        const PhysicsSample(
          speedMps: 20.0,
          accelerationMps2: 0.0,
          inclinePercent: -8.0,
          measuredDriveW: -9000.0,
        ),
        params,
      );

      expect(breakdown.gradeW!, lessThan(0.0));
      expect(breakdown.modelRoadW!, lessThan(0.0));
      expect(breakdown.regenRecoveredW, 9000.0);

      // Efficiency must multiply here, not divide. Dividing would make the
      // model demand more return than the road can give and report a fault.
      final batterySide = breakdown.modelRoadW! * params.regenEfficiency;
      expect(breakdown.residualRoadW, closeTo(-9000.0 - batterySide, 1e-6));
    });

    test('hard braking splits regeneration from the friction brakes', () {
      // 20 m/s, decelerating at 3 m/s^2, on the level, with the pedal down.
      final breakdown = computeBreakdown(
        const PhysicsSample(
          speedMps: 20.0,
          accelerationMps2: -3.0,
          inclinePercent: 0.0,
          measuredDriveW: -25000.0,
          measuredPackW: -24500.0,
          brakePedalOn: true,
        ),
        params,
      );

      // 1550 kg * 1.04 * -3 m/s^2 * 20 m/s
      expect(breakdown.kineticW, closeTo(-96720.0, 1.0));
      expect(breakdown.modelRoadW!, lessThan(0.0));

      // The road demands about 90 kW back; regeneration at the road supplies
      // 25 kW / 0.88. The pads take the rest, and the number must be positive.
      final regenAtRoad = 25000.0 / params.regenEfficiency;
      expect(
        breakdown.frictionBrakeW,
        closeTo(-breakdown.modelRoadW! - regenAtRoad, 1e-6),
      );
      expect(breakdown.frictionBrakeW!, greaterThan(0.0));
    });

    test('gentle braking inside regeneration charges the pads nothing', () {
      final breakdown = computeBreakdown(
        const PhysicsSample(
          speedMps: 15.0,
          accelerationMps2: -0.4,
          inclinePercent: 0.0,
          measuredDriveW: -20000.0,
          brakePedalOn: true,
        ),
        params,
      );

      expect(breakdown.frictionBrakeW, 0.0);
    });

    test('a released pedal is a measured zero, an absent one is null', () {
      const decelerating = PhysicsSample(
        speedMps: 20.0,
        accelerationMps2: -3.0,
        inclinePercent: 0.0,
        measuredDriveW: -5000.0,
      );

      expect(computeBreakdown(decelerating, params).frictionBrakeW, isNull);

      final released = computeBreakdown(
        const PhysicsSample(
          speedMps: 20.0,
          accelerationMps2: -3.0,
          inclinePercent: 0.0,
          measuredDriveW: -5000.0,
          brakePedalOn: false,
        ),
        params,
      );
      expect(released.frictionBrakeW, 0.0);
    });

    test('standstill with a load is all auxiliary and no road', () {
      // Session B, all loads off: pack 159.3 W, drive at raw 2040 = 0 kW.
      final breakdown = computeBreakdown(
        const PhysicsSample(
          speedMps: 0.0,
          accelerationMps2: 0.0,
          inclinePercent: 0.0,
          measuredDriveW: 0.0,
          measuredPackW: 159.3,
        ),
        params,
      );

      expect(breakdown.rollingW, 0.0);
      expect(breakdown.aeroW, 0.0);
      expect(breakdown.gradeW, 0.0);
      expect(breakdown.kineticW, 0.0);
      expect(breakdown.modelRoadW, 0.0);

      // The offset is pinned, not fitted: a stationary unloaded car must give
      // exactly zero road residual, or the model has an additive error.
      expect(breakdown.residualRoadW, 0.0);
      expect(breakdown.unattributedAuxW, closeTo(159.3, 1e-9));
    });

    test('the heater leaves the bucket only when the PTC says so', () {
      // Session B, A/C max hot: pack 2896.6 W, thermal raw 32.
      const hot = PhysicsSample(
        speedMps: 0.0,
        accelerationMps2: 0.0,
        inclinePercent: 0.0,
        measuredDriveW: 0.0,
        measuredPackW: 2896.6,
        thermalRaw: 32,
        ptcHeating: true,
      );

      final heating = computeBreakdown(hot, params);
      expect(heating.heaterW, closeTo(3040.0, 1e-9));
      // The seed scale overshoots this sample by about 5 %, which is inside the
      // +/-20 % the two calibration steps support.
      expect(heating.unattributedAuxW!.abs(), lessThan(0.2 * 2896.6));

      // Same thermal counts, indicator clear: the draw is cooling or unknown,
      // and it must stay in the bucket rather than be scaled by a heater scale.
      final cooling = computeBreakdown(
        const PhysicsSample(
          speedMps: 0.0,
          accelerationMps2: 0.0,
          inclinePercent: 0.0,
          measuredDriveW: 0.0,
          measuredPackW: 557.3,
          thermalRaw: 1,
          ptcHeating: false,
        ),
        params,
      );
      expect(cooling.heaterW, isNull);
      expect(cooling.unattributedAuxW, closeTo(557.3, 1e-9));
    });

    test('an unpublished incline makes the sum null, not smaller', () {
      final breakdown = computeBreakdown(
        const PhysicsSample(
          speedMps: 20.0,
          accelerationMps2: 0.0,
          measuredDriveW: 6000.0,
          measuredPackW: 6400.0,
        ),
        params,
      );

      expect(breakdown.gradeW, isNull);
      expect(breakdown.modelRoadW, isNull);
      expect(breakdown.residualRoadW, isNull);

      // R_aux does not depend on the road model, so it survives.
      expect(breakdown.unattributedAuxW, closeTo(400.0, 1e-9));
    });

    test('missing bus power yields nulls, never zeros', () {
      final breakdown = computeBreakdown(
        const PhysicsSample(
          speedMps: 20.0,
          accelerationMps2: 0.0,
          inclinePercent: 0.0,
        ),
        params,
      );

      expect(breakdown.modelRoadW, isNotNull);
      expect(breakdown.measuredDriveW, isNull);
      expect(breakdown.totalAuxW, isNull);
      expect(breakdown.unattributedAuxW, isNull);
      expect(breakdown.residualRoadW, isNull);
      expect(breakdown.regenRecoveredW, isNull);
    });
  });

  group('estimateAcceleration', () {
    test('recovers a constant acceleration exactly', () {
      final samples = series(4.0, 5.0, (t) => 2.0 + 1.5 * t);
      expect(estimateAcceleration(samples, 10), closeTo(1.5, 1e-9));
    });

    test('is exact on a parabola, which a finite difference is not', () {
      // v = 3 + 0.5 t^2, so a = t. At t = 2.0 the answer is 2.0.
      final samples = series(4.0, 5.0, (t) => 3.0 + 0.5 * t * t);
      expect(estimateAcceleration(samples, 10), closeTo(2.0, 1e-9));
    });

    test('survives quantized speed where a finite difference does not', () {
      // 5 Hz, quantized to 0.1 m/s, accelerating at 0.7 m/s^2. The rate is
      // deliberately not a whole number of quanta per sample: at exactly
      // 1.0 m/s^2 each step is 2 quanta and the quantization cancels, which
      // would make this test pass for the wrong reason.
      const quantum = 0.1;
      const truth = 0.7;
      final samples = series(
        6.0,
        5.0,
        (t) => ((10.0 + truth * t) / quantum).roundToDouble() * quantum,
      );

      final fitted = estimateAcceleration(samples, 15)!;
      final finiteDifference =
          (samples[15].speedMps - samples[14].speedMps) / 0.2;

      expect(fitted, closeTo(truth, 0.05));

      // The naive derivative can only land on a multiple of quantum/dt = 0.5,
      // so it cannot report 0.7 at all. It is wrong by at least 0.2 here, and
      // it alternates between 0.5 and 1.0 from sample to sample.
      expect(
        (finiteDifference * 2.0).roundToDouble() / 2.0,
        closeTo(finiteDifference, 1e-9),
      );
      expect((finiteDifference - truth).abs(), greaterThan(0.15));
    });

    test('handles a dropped frame, which fixed coefficients would not', () {
      final samples = series(4.0, 5.0, (t) => 2.0 + 1.5 * t)
        ..removeAt(9)
        ..removeAt(9);
      final index = samples.indexWhere((s) => s.timeSeconds == 2.4);
      expect(index, isNot(-1));
      expect(estimateAcceleration(samples, index), closeTo(1.5, 1e-9));
    });

    test('refuses a window that cannot define a derivative', () {
      expect(estimateAcceleration(const [], 0), isNull);
      expect(
        estimateAcceleration(const [
          SpeedSample(0.0, 10.0),
          SpeedSample(0.2, 10.5),
        ], 1),
        isNull,
      );
      // Three samples that share one timestamp span no time at all.
      expect(
        estimateAcceleration(const [
          SpeedSample(1.0, 10.0),
          SpeedSample(1.0, 10.0),
          SpeedSample(1.0, 10.0),
        ], 1),
        isNull,
      );
      expect(estimateAcceleration(series(4.0, 5.0, (t) => t), -1), isNull);
    });

    test('does not invent a slope at the ends of the series', () {
      final samples = series(4.0, 5.0, (t) => 2.0 + 1.5 * t);
      expect(estimateAcceleration(samples, 0), closeTo(1.5, 1e-9));
      expect(
        estimateAcceleration(samples, samples.length - 1),
        closeTo(1.5, 1e-9),
      );
    });
  });

  group('the model against itself', () {
    test('a cruise residual is small when the seeds are the truth', () {
      // Build a synthetic car that obeys the seed parameters exactly, then
      // check the model recovers zero residual. This pins the algebra, not the
      // constants: it is the only assertion here that the real car cannot fail.
      const v = 22.0;
      final rolling =
          params.rollingResistanceCoefficient * params.massKg * 9.80665 * v;
      final aero =
          0.5 * params.airDensityKgPerM3 * params.dragAreaM2 * math.pow(v, 3);
      final driveW = (rolling + aero) / params.tractionEfficiency;

      final breakdown = computeBreakdown(
        PhysicsSample(
          speedMps: v,
          accelerationMps2: 0.0,
          inclinePercent: 0.0,
          measuredDriveW: driveW,
        ),
        params,
      );

      expect(breakdown.residualRoadW!.abs(), lessThan(1e-6));
    });

    test('the regeneration efficiency moves only the regeneration side', () {
      // One number used in both directions asserts that the two paths are
      // equally lossy, and the residual then has no way to disagree. Changing
      // the return path must leave a cruise untouched and move a coast.
      final lossyReturn = params.copyWith(regenEfficiency: 0.70);

      const cruise = PhysicsSample(
        speedMps: 22.0,
        accelerationMps2: 0.0,
        inclinePercent: 0.0,
        measuredDriveW: 12000.0,
      );
      expect(
        computeBreakdown(cruise, lossyReturn).residualRoadW,
        closeTo(computeBreakdown(cruise, params).residualRoadW!, 1e-9),
      );

      const coast = PhysicsSample(
        speedMps: 22.0,
        accelerationMps2: -1.5,
        inclinePercent: 0.0,
        measuredDriveW: -20000.0,
      );
      expect(
        computeBreakdown(coast, lossyReturn).residualRoadW,
        isNot(closeTo(computeBreakdown(coast, params).residualRoadW!, 1.0)),
      );
    });

    test('a worse return path charges the pads for more of the stop', () {
      // The pack received a fixed amount. A lossier return means the road had
      // to supply more to deliver it, so less of the demand is left for the
      // friction brakes, not more.
      const braking = PhysicsSample(
        speedMps: 20.0,
        accelerationMps2: -3.0,
        inclinePercent: 0.0,
        measuredDriveW: -25000.0,
        brakePedalOn: true,
      );

      final seeded = computeBreakdown(braking, params).frictionBrakeW!;
      final lossy = computeBreakdown(
        braking,
        params.copyWith(regenEfficiency: 0.70),
      ).frictionBrakeW!;

      expect(lossy, lessThan(seeded));
    });
  });
}
