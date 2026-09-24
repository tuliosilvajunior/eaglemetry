/// The road-load model, and the two residuals the car can support.
///
/// This file is the Stage 3 road-load model. It is pure: it
/// imports nothing but `dart:math`, reads no channel, and holds no state. Give
/// it one sample and a parameter set, and it answers with a breakdown.
///
/// It computes **two** residuals, not the three the original specification
/// asked for. The third needed mechanical axle power, `IPU_MOTOR_TQ ×
/// IPU_MOTOR_SPD`, and the awake property scan of 2026-08-07 settled that
/// neither property ever publishes on this car:
///
/// ```
/// P_road_mod = P_rolling + P_aero + P_grade + P_kinetic
///
/// R_aux  = P_pack  − P_drive          // clean: both terms are calibrated
/// R_road = P_drive − P_road_mod / η   // confounded, see below
/// ```
///
/// [PowerBreakdown.unattributedAux] is the honest form of the app's existing
/// `aux = packKw − driveKw`. Both of its terms are calibrated signals, so the
/// subtraction is real. Only the PTC heater can leave that bucket, and only
/// while the car says the heater is the load.
///
/// [PowerBreakdown.residualRoad] mixes two errors that cannot be separated by
/// subtraction: the road-load model being wrong, and the powertrain conversion
/// being lossier than [VehicleParams.tractionEfficiency] assumes. Without
/// axle power there is no boundary between them. Anything that displays this
/// number must say so. They separate partly by *shape*, and only over a wide
/// speed range — an efficiency error scales the whole model, a rolling error
/// grows with `v`, an aero error with `v³` — which is why the coastdown routine
/// belongs on highway data or nowhere.
///
/// One thing is pinned rather than fitted. At standstill the model is zero and
/// `VCU_DrvPwrAct` reads raw 2040, which is 0.00 kW, in all twelve stationary
/// samples. The additive
/// offset is therefore known to be zero, and only the multiplicative terms are
/// free.
library;

import 'dart:math' as math;

/// Standard gravity, m/s².
const double _g = 9.80665;

/// The constants the road-load model divides and multiplies by.
///
/// Every value here is a **seed**, not a measurement. The `CALIB` tab of Stage 6
/// derives real ones by coastdown and writes them to a versioned
/// `CalibrationProfile`; until that exists, these are the documented starting
/// point, and nothing in this file hard-codes any of them.
///
/// Treat the seeds as accurate to no better than ±20 %. The model built on them
/// is useful for *shape* — how a residual grows with speed — long before it is
/// useful for magnitude.
class VehicleParams {
  const VehicleParams({
    this.massKg = 1550.0,
    this.rollingResistanceCoefficient = 0.011,
    this.dragAreaM2 = 0.72,
    this.airDensityKgPerM3 = 1.2,
    this.tractionEfficiency = 0.88,
    this.regenEfficiency = 0.88,
    this.rotatingMassFactor = 1.04,
    this.heaterWattsPerBit = 95.0,
  });

  /// Kerb mass plus a driver. Payload is not measured, so this is a seed.
  final double massKg;

  /// Rolling resistance coefficient, dimensionless.
  final double rollingResistanceCoefficient;

  /// Drag coefficient times frontal area, m². The product is what a coastdown
  /// can recover; the two factors separately are not observable here.
  final double dragAreaM2;

  /// Air density. A constant, because the car publishes no barometric pressure.
  /// It varies by roughly 10 % over the temperature and altitude range this car
  /// sees, and that error lands in [PowerBreakdown.residualRoad] with all the
  /// others.
  final double airDensityKgPerM3;

  /// Battery-to-wheel efficiency while driving the car forward.
  ///
  /// This is an assumption and it stays one. The XY tab was meant to replace it
  /// with a measured efficiency map, which needed the motor pair this car does
  /// not publish. See the class comment for which residual it contaminates.
  final double tractionEfficiency;

  /// Wheel-to-battery efficiency while regenerating.
  ///
  /// A separate number from [tractionEfficiency], and the two seeds are equal
  /// only because nothing has measured them apart yet. They are not the same
  /// quantity: the path back through the motor, the inverter and into the pack
  /// is not the path out, and on most drivetrains it is the worse of the two.
  ///
  /// The split matters even before either is measured, because one number used
  /// in both directions asserts that they are equal, and the residual then has
  /// no way to disagree. They are separately identifiable from recorded data:
  /// the sign of `VCU_DrvPwrAct` labels which regime each frame belongs to, so
  /// a fit over history can move one without the other.
  final double regenEfficiency;

  /// Equivalent-mass multiplier for wheels and driveline that must also be spun
  /// up. Applies to the kinetic term only.
  final double rotatingMassFactor;

  /// Scale for `VCU_ThermalPwrAct`, W per bit.
  ///
  /// Derived from two heating steps against their own session baselines:
  /// 104.5 and 85.5 W/bit. The midpoint is used, and it is not tighter than
  /// about ±20 %. It is valid for **heating only**; the cooling response of the
  /// same signal was measured at 159 and 398 W/bit on two occasions, so no
  /// fixed scale recovers it. See the evidence file named in the class comment.
  final double heaterWattsPerBit;

  VehicleParams copyWith({
    double? massKg,
    double? rollingResistanceCoefficient,
    double? dragAreaM2,
    double? airDensityKgPerM3,
    double? tractionEfficiency,
    double? regenEfficiency,
    double? rotatingMassFactor,
    double? heaterWattsPerBit,
  }) {
    return VehicleParams(
      massKg: massKg ?? this.massKg,
      rollingResistanceCoefficient:
          rollingResistanceCoefficient ?? this.rollingResistanceCoefficient,
      dragAreaM2: dragAreaM2 ?? this.dragAreaM2,
      airDensityKgPerM3: airDensityKgPerM3 ?? this.airDensityKgPerM3,
      tractionEfficiency: tractionEfficiency ?? this.tractionEfficiency,
      regenEfficiency: regenEfficiency ?? this.regenEfficiency,
      rotatingMassFactor: rotatingMassFactor ?? this.rotatingMassFactor,
      heaterWattsPerBit: heaterWattsPerBit ?? this.heaterWattsPerBit,
    );
  }
}

/// One instant, as the bus reported it.
///
/// Everything optional is optional because the car may not have published it.
/// A null is never replaced by a zero anywhere in this file: a zero asserts a
/// measurement, a null admits the absence of one.
class PhysicsSample {
  const PhysicsSample({
    required this.speedMps,
    required this.accelerationMps2,
    this.inclinePercent,
    this.measuredDriveW,
    this.measuredPackW,
    this.thermalRaw,
    this.ptcHeating,
    this.brakePedalOn,
  });

  /// Ground speed, m/s. Never negative; the car publishes no reverse sign.
  final double speedMps;

  /// Longitudinal acceleration, m/s².
  ///
  /// This must come from [estimateAcceleration], not from a finite difference
  /// between two speed samples. See that function for why.
  final double accelerationMps2;

  /// `ESC_RoadInclnRoadIncln`, in percent, positive uphill.
  ///
  /// The sign convention is **not yet verified against the road**. It needs one
  /// out-and-back drive with GPS on. Until then the grade term carries an
  /// unresolved sign risk, and a reversed sign does not merely shrink the
  /// residual, it doubles it.
  final double? inclinePercent;

  /// `VCU_DrvPwrAct`, W. Battery-side traction power, positive when drawing.
  final double? measuredDriveW;

  /// `BMSH_BattVolt × BMSH_BattCurr`, W. Positive when the pack is discharging.
  final double? measuredPackW;

  /// `VCU_ThermalPwrAct`, raw counts. Unscaled on purpose.
  final int? thermalRaw;

  /// `AC_PTCHeatIndicator`. The gate on scaling [thermalRaw] at all.
  final bool? ptcHeating;

  /// `ESC_BrakePedalSwitch`, already resolved against its `*Invalid` companion.
  final bool? brakePedalOn;
}

/// What the model and the bus each say about one instant, in watts.
class PowerBreakdown {
  const PowerBreakdown({
    required this.rollingW,
    required this.aeroW,
    required this.gradeW,
    required this.kineticW,
    required this.modelRoadW,
    required this.measuredDriveW,
    required this.measuredPackW,
    required this.heaterW,
    required this.unattributedAuxW,
    required this.residualRoadW,
    required this.frictionBrakeW,
    required this.regenRecoveredW,
  });

  /// Rolling resistance at the road, W. Zero at standstill.
  final double rollingW;

  /// Aerodynamic drag at the road, W. Grows with the cube of speed.
  final double aeroW;

  /// Gravity along the slope, W. Negative downhill. Null when the car did not
  /// publish an incline — the model cannot assume level ground, because level
  /// is a measurement like any other.
  final double? gradeW;

  /// Inertia, W. Negative while decelerating.
  final double kineticW;

  /// The four terms above, summed: mechanical power demanded at the road.
  /// Null whenever [gradeW] is null, because a sum missing a term is not a
  /// smaller sum, it is a different quantity.
  final double? modelRoadW;

  /// `VCU_DrvPwrAct` as given, W.
  final double? measuredDriveW;

  /// Pack power as given, W.
  final double? measuredPackW;

  /// Heater draw, W, and **null unless the PTC indicator says so**.
  ///
  /// The null is load-bearing and must stay. A zero would assert that no heat
  /// was drawn; a null says the draw could not be attributed, which is the true
  /// statement whenever the indicator is clear. This is the same distinction
  /// `EfficiencyState` makes between `still` and `unreported`.
  final double? heaterW;

  /// `R_aux` minus [heaterW], W.
  ///
  /// Cooling, the 12 V draw, and error. A display must name it that way. It is
  /// not "losses": no signal on this bus measures compressor power, and
  /// `VCU_DCDCPwrAct` has no scale, so both are inside this number by
  /// necessity rather than by choice.
  final double? unattributedAuxW;

  /// `R_road`, W, signed. Confounded — see the library comment.
  final double? residualRoadW;

  /// Estimated friction braking at the road, W, positive when braking.
  ///
  /// Null when the brake state is unknown, for the same reason as [heaterW].
  /// This departs from the shape drafted in the plan, which made the field
  /// non-nullable; a zero here would claim the brakes were measured and idle.
  final double? frictionBrakeW;

  /// Battery-side power recovered by regeneration, W, positive when recovering.
  final double? regenRecoveredW;

  /// `R_aux` before the heater is taken out: pack minus traction.
  double? get totalAuxW {
    final pack = measuredPackW;
    final drive = measuredDriveW;
    if (pack == null || drive == null) return null;
    return pack - drive;
  }
}

/// The road-load model for one instant.
///
/// Returns nulls rather than substitutes for every term the car did not report.
PowerBreakdown computeBreakdown(PhysicsSample sample, VehicleParams params) {
  final v = math.max(sample.speedMps, 0.0);
  final incline = sample.inclinePercent;

  // Percent grade is rise over run, which is tan θ, not sin θ. At 10 % the two
  // differ by 0.5 %, so the distinction is negligible on any road this car
  // drives — but it is free, and a model that quietly conflates them invites
  // the reader to trust the next approximation too.
  final double? sinTheta;
  final double cosTheta;
  if (incline == null) {
    sinTheta = null;
    cosTheta = 1.0;
  } else {
    final tanTheta = incline / 100.0;
    final hypotenuse = math.sqrt(1.0 + tanTheta * tanTheta);
    sinTheta = tanTheta / hypotenuse;
    cosTheta = 1.0 / hypotenuse;
  }

  final rollingW =
      params.rollingResistanceCoefficient * params.massKg * _g * cosTheta * v;
  final aeroW = 0.5 * params.airDensityKgPerM3 * params.dragAreaM2 * v * v * v;
  final gradeW = sinTheta == null ? null : params.massKg * _g * sinTheta * v;
  final kineticW =
      params.massKg * params.rotatingMassFactor * sample.accelerationMps2 * v;

  final modelRoadW = gradeW == null
      ? null
      : rollingW + aeroW + gradeW + kineticW;

  final heaterW = (sample.ptcHeating == true && sample.thermalRaw != null)
      ? sample.thermalRaw! * params.heaterWattsPerBit
      : null;

  final pack = sample.measuredPackW;
  final drive = sample.measuredDriveW;
  final totalAuxW = (pack == null || drive == null) ? null : pack - drive;
  final unattributedAuxW = totalAuxW == null
      ? null
      : totalAuxW - (heaterW ?? 0.0);

  final residualRoadW = (drive == null || modelRoadW == null)
      ? null
      : drive - _toBatterySide(modelRoadW, params);

  final regenRecoveredW = drive == null ? null : math.max(-drive, 0.0);

  return PowerBreakdown(
    rollingW: rollingW,
    aeroW: aeroW,
    gradeW: gradeW,
    kineticW: kineticW,
    modelRoadW: modelRoadW,
    measuredDriveW: drive,
    measuredPackW: pack,
    heaterW: heaterW,
    unattributedAuxW: unattributedAuxW,
    residualRoadW: residualRoadW,
    frictionBrakeW: _frictionBrakeW(sample, modelRoadW, drive, params),
    regenRecoveredW: regenRecoveredW,
  );
}

/// Converts mechanical power at the road to the battery-side power it implies.
///
/// The efficiency divides on the way out and multiplies on the way back. Using
/// one direction for both would make every deceleration look like a fault.
///
/// Each direction has its own efficiency, because they are different paths
/// through the same hardware. See [VehicleParams.regenEfficiency].
double _toBatterySide(double mechanicalW, VehicleParams params) {
  if (mechanicalW >= 0) {
    final efficiency = params.tractionEfficiency;
    return efficiency <= 0 ? mechanicalW : mechanicalW / efficiency;
  }
  return mechanicalW * params.regenEfficiency.clamp(0.0, 1.0);
}

/// Friction braking the regenerative brake did not account for.
///
/// The road demands negative power; regeneration supplies part of it; whatever
/// is left had to become heat in the pads. Gated on the brake switch, so a
/// coasting car with a model error does not get charged for braking it never
/// did.
double? _frictionBrakeW(
  PhysicsSample sample,
  double? modelRoadW,
  double? driveW,
  VehicleParams params,
) {
  final braking = sample.brakePedalOn;
  if (braking == null || modelRoadW == null || driveW == null) return null;
  if (!braking) return 0.0;
  if (modelRoadW >= 0) return 0.0;

  final demandedAtRoadW = -modelRoadW;
  // The pack received this much; the road had to supply more, by the
  // regeneration efficiency and not by the traction one.
  final regenAtRoadW = params.regenEfficiency <= 0
      ? 0.0
      : math.max(-driveW, 0.0) / params.regenEfficiency;
  return math.max(demandedAtRoadW - regenAtRoadW, 0.0);
}

/// One speed reading with the time it was taken.
class SpeedSample {
  const SpeedSample(this.timeSeconds, this.speedMps);

  final double timeSeconds;
  final double speedMps;
}

/// Acceleration at [index], by local least-squares quadratic fit.
///
/// **Never take a finite difference between two speed samples here.** VHAL
/// speed arrives at about 5 Hz and is quantized. A difference of two quantized
/// values over a 0.2 s gap amplifies the quantization by five, and the kinetic
/// term multiplies that noise by mass — around 1.6 kW per quantum at 20 m/s.
/// The noise would then dominate every term the model exists to separate.
///
/// This is the Savitzky-Golay derivative the plan asks for, written as the
/// least-squares fit that Savitzky-Golay is, rather than as fixed coefficients.
/// The fixed-coefficient form assumes evenly spaced samples, and CAN samples
/// are not evenly spaced: a dropped frame would silently rescale the
/// derivative. Fitting against the real timestamps costs a few multiplications
/// and removes that failure.
///
/// [halfWindow] is in samples on each side. Returns null when fewer than three
/// points are available or when they span no time, because a derivative of one
/// instant is not a small derivative, it is not a derivative.
double? estimateAcceleration(
  List<SpeedSample> samples,
  int index, {
  int halfWindow = 4,
}) {
  if (index < 0 || index >= samples.length) return null;

  final start = math.max(0, index - halfWindow);
  final end = math.min(samples.length - 1, index + halfWindow);
  final count = end - start + 1;
  if (count < 3) return null;

  // Centre the fit on the sample of interest so the quadratic's first
  // derivative at t = 0 is the answer, with no back-substitution.
  final t0 = samples[index].timeSeconds;

  var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0;
  var b0 = 0.0, b1 = 0.0, b2 = 0.0;
  for (var i = start; i <= end; i++) {
    final t = samples[i].timeSeconds - t0;
    final y = samples[i].speedMps;
    final t2 = t * t;
    s0 += 1;
    s1 += t;
    s2 += t2;
    s3 += t2 * t;
    s4 += t2 * t2;
    b0 += y;
    b1 += t * y;
    b2 += t2 * y;
  }

  // Solve the 3x3 normal equations by Cramer's rule. The determinant vanishes
  // exactly when the samples share too few distinct timestamps to define a
  // parabola, which is the degenerate case worth refusing.
  final det =
      s0 * (s2 * s4 - s3 * s3) -
      s1 * (s1 * s4 - s3 * s2) +
      s2 * (s1 * s3 - s2 * s2);
  if (det.abs() < 1e-12) return null;

  final detB =
      s0 * (b1 * s4 - b2 * s3) -
      b0 * (s1 * s4 - s3 * s2) +
      s2 * (s1 * b2 - b1 * s2);

  final acceleration = detB / det;
  return acceleration.isFinite ? acceleration : null;
}
