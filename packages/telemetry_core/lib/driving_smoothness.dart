/// How steadily the car is being driven, over a trailing window.
///
/// This replaces the instantaneous range-impact ratio the pill used to show.
/// That reading was `speed / drivePower` against a fixed km/kWh reference, and
/// it failed in three separate ways that the replacement is shaped to avoid.
///
/// ## Why the ratio had to go
///
/// **It ranked driving styles backwards.** Simulated over an urban cycle with
/// this car's own parameters, the aggressive driver spent *more* time above
/// neutral than the gentle one (72.8 % against 66.3 %) while costing 111 Wh/km
/// against 93. The cause is structural: `speed / power` has the pedal in the
/// denominator and nothing else moves as fast, so the reading tracked the duty
/// cycle of the accelerator. Driving harder shortens the acceleration phase and
/// lengthens the coast that follows, and the coast pinned to the top.
///
/// **Efficiency is energy over distance, and an instant has no distance in
/// it.** Kinetic energy is a loan, not a cost — this car returns 40 to 47 % of
/// it — but the ratio charged the whole amount while accelerating and credited
/// an unbounded number while coasting. It measured which half of the
/// spend-and-recover cycle the car was in.
///
/// **It was a speedometer wearing a costume.** Holding a steady speed, which is
/// the same correct act at any speed, read 1.00 at 30 km/h and 0.48 at 90.
///
/// A fourth defect went with it rather than being repaired: the numerator was
/// `VCU_DrvPwrAct`, which is traction only, while the reference came from
/// `energyKwhEstimate`, which is SOC-derived and therefore includes the ~480 W
/// of auxiliaries measured on the car. The
/// pill read 42 % optimistic at 20 km/h and 5 % at 80. This reading needs no
/// efficiency reference at all, so the mismatch has nowhere left to live.
///
/// ## What this reads instead
///
/// The rate at which tractive power is being changed, per kilometre travelled.
/// A driver holding a speed changes power very little over the distance
/// covered; a driver accelerating hard and braking hard changes it a great
/// deal. Across the same simulation this ranks gentle, normal and aggressive in
/// the right order, spreads across 0.30 of the track rather than 0.09, and
/// reads flat at every steady speed from 30 to 90 km/h.
///
/// It needs only `VCU_DrvPwrAct` and the VHAL speed, both calibrated. It
/// deliberately needs no efficiency map — this car publishes neither
/// `IPU_MOTOR_TQ` nor `IPU_MOTOR_SPD`, so battery-side power cannot be split
/// into work and loss, and `VehicleParams.tractionEfficiency` is a ±20 % seed.
/// It needs no road-load fit either, which is blocked: this car has no road-load fit.
///
/// ## What it does not claim
///
/// **This is technique, not efficiency, and it must never be labelled
/// efficiency.** It is speed-independent by construction, so it says nothing
/// about the choice of speed — smooth driving at 120 km/h scores well while
/// costing a great deal. That is the correct division of labour on this card:
/// the numeral and the two-line chart already answer what the driving cost, in
/// km/kWh and Wh/km. The pill answers the one thing a driver can act on inside
/// the next few seconds.
library;

import 'dart:collection';
import 'dart:math' as math;

/// How far back the knob reads.
///
/// Thirty seconds. Below fifteen the ranking breaks down, because a single
/// acceleration fills the whole window and every driver looks the same inside
/// one. Sixty separates the styles further still but takes a full minute to
/// forgive a burst, by which time the driver has stopped connecting the reading
/// to what they did.
const Duration kSmoothnessWindow = Duration(seconds: 30);

/// How far back the fast mark reads.
///
/// Five seconds: long enough to survive one gear-free power step, short enough
/// that it answers "now". The mark exists to be compared against the knob, and
/// the gap between them is the whole message — ahead of your recent driving, or
/// behind it.
const Duration kSmoothnessInstantWindow = Duration(seconds: 5);

/// Power ramp per kilometre that sits at the middle of the track, in kW/km.
///
/// **This is a seed and it must be calibrated against recorded trips.** It
/// comes from the urban simulation that chose this reading, replayed through
/// this file's own arithmetic at 60 Hz with `VCU_DrvPwrAct` quantised to its
/// real 0.1 kW: the gentle, normal and aggressive drivers produced 231, 432 and
/// 774 kW/km. The value is the middle one, so an ordinary drive lands on
/// neutral and the two halves of the track mean "smoother than usual" and
/// "harsher than usual" rather than naming an absolute virtue. Gentle then
/// reads 0.73 and aggressive 0.10.
///
/// The honest replacement is the driver's own median over the same seven-day
/// window the range estimate uses, which would make the pill self-referential
/// and remove this constant. That needs the ramp to be reduced and stored per
/// trip, so it is deliberately left as follow-up work rather than guessed at
/// here.
const double kSmoothnessReferenceRampKwPerKm = 430.0;

/// Speed below which an interval counts as not having moved, in km/h.
///
/// Two km/h, the same floor `kEfficiencyMinSpeedKmh` applies for the same
/// reason: slow enough that a crawl in traffic still registers, fast enough
/// that noise around a standstill does not read as motion.
const double kSmoothnessMinSpeedKmh = 2.0;

/// Interval the ramp is measured on, rather than at the rate CAN is sampled.
///
/// `VCU_DrvPwrAct` resolves to 0.1 kW. Summing `|dP|` over a 60 Hz sample train
/// would integrate the dither of the least significant bit into a large
/// spurious ramp — one quantum of jitter per sample is 6 kW/s, which over
/// thirty seconds swamps every real acceleration in the window. Resampling onto
/// a fixed 200 ms grid drops that by more than an order of magnitude, and the
/// deadband below removes what is left. A genuine ramp is unaffected: the sum
/// of `|dP|` along a monotonic run does not depend on how often it is sampled.
const Duration kSmoothnessSampleInterval = Duration(milliseconds: 200);

/// Power change below which a step counts as no step, in kW.
///
/// One and a half quanta of `VCU_DrvPwrAct`. Above the signal's own resolution,
/// far below any change a driver could make on purpose.
const double kSmoothnessDeadbandKw = 0.15;

/// Gap after which two samples are not treated as consecutive.
///
/// Two seconds. A pause, a backgrounded app or a bus that went quiet leaves a
/// hole, and the power difference across that hole describes nothing the driver
/// did. It restarts the run instead of being counted.
const Duration kSmoothnessMaxGap = Duration(seconds: 2);

/// How long a reading survives once the car stops moving.
///
/// Three minutes. A stopped car has no smoothness to measure, but emptying the
/// pill at every red light would read as a fault rather than as a stop, so the
/// last reading is held. It is dropped eventually because a car that has been
/// stationary for minutes is no longer described by how it was driven before.
const Duration kSmoothnessHold = Duration(minutes: 3);

/// What the pill is showing.
enum SmoothnessState {
  /// The window covered enough distance to divide by.
  measured,

  /// Not moving now, showing the last reading that was measured. A stop, not a
  /// fault — see [kSmoothnessHold].
  held,

  /// Nothing to show: no signal, or nothing measured recently enough to hold.
  unavailable,
}

/// One reading of driving smoothness.
class DrivingSmoothness {
  const DrivingSmoothness({
    required this.state,
    this.standing,
    this.instant,
    this.rampKwPerKm,
  });

  static const unavailable = DrivingSmoothness(
    state: SmoothnessState.unavailable,
  );

  final SmoothnessState state;

  /// Where the knob sits, 0 at the floor and 1 at the top, neutral at 0.5.
  ///
  /// Null only when [state] is [SmoothnessState.unavailable].
  final double? standing;

  /// Where the fast mark sits, on the same scale.
  ///
  /// Null whenever the last [kSmoothnessInstantWindow] did not cover enough
  /// distance to divide by, which includes every stop. The mark is then not
  /// drawn, rather than being placed somewhere that would imply a measurement.
  final double? instant;

  /// The raw reading behind [standing], in kW/km. Diagnostics only.
  final double? rampKwPerKm;

  bool get hasKnob => state != SmoothnessState.unavailable;

  /// Whether the recent driving was smoother than the reference ramp.
  ///
  /// This is what colours the knob. It follows [standing] and never [instant],
  /// so the colour does not flicker with the pedal.
  bool get aboveNeutral => (standing ?? 0) >= 0.5;

  /// Whether this moment is better than the recent standing.
  ///
  /// Null when either mark is missing. The pill draws the two marks and lets
  /// the gap speak; this is here for tests and diagnostics rather than for the
  /// painter.
  bool? get improving =>
      (standing == null || instant == null) ? null : instant! > standing!;

  @override
  bool operator ==(Object other) =>
      other is DrivingSmoothness &&
      other.state == state &&
      other.standing == standing &&
      other.instant == instant &&
      other.rampKwPerKm == rampKwPerKm;

  @override
  int get hashCode => Object.hash(state, standing, instant, rampKwPerKm);
}

/// Turns a power ramp per kilometre into a position on the track.
///
/// Zero ramp is the top; twice the reference is the floor. Expressed as a free
/// function so the mapping can be asserted without building a tracker.
double smoothnessScore(
  double rampKwPerKm, {
  double reference = kSmoothnessReferenceRampKwPerKm,
}) {
  if (reference <= 0 || !reference.isFinite || !rampKwPerKm.isFinite) return 0;
  return (1 - rampKwPerKm / (2 * reference)).clamp(0.0, 1.0);
}

/// Distance a window of [width] must cover before a ramp is divided by it.
///
/// A rate rather than a fixed amount, for the reason
/// `efficiencyDistanceFloorKm` states: the same judgement has to hold at five
/// seconds and at thirty, and a constant that suits one lets a barely-moving
/// car through the other, where the tiny distance divides into a large ramp.
double smoothnessDistanceFloorKm(Duration width) =>
    kSmoothnessMinSpeedKmh *
    width.inMilliseconds /
    Duration.millisecondsPerHour;

/// One resampled step of driving.
class _Step {
  const _Step(this.atMillis, this.rampKw, this.distanceKm);

  final int atMillis;

  /// `|dP|` since the previous step, after the deadband.
  final double rampKw;

  /// Distance covered during the step.
  final double distanceKm;
}

/// Folds live speed and traction power into a [DrivingSmoothness].
///
/// Stateful because the reading is a window, and pure otherwise: it reads no
/// channel and holds no timer. The caller supplies the clock, which is what
/// lets a test drive it without one.
class SmoothnessTracker {
  SmoothnessTracker({this.reference = kSmoothnessReferenceRampKwPerKm});

  /// Ramp per kilometre that sits at neutral. See
  /// [kSmoothnessReferenceRampKwPerKm].
  final double reference;

  final Queue<_Step> _steps = ListQueue<_Step>();

  int? _lastSampleMillis;
  double? _lastPowerKw;

  /// The last measured standing, kept so a stop holds rather than empties.
  double? _heldStanding;
  double? _heldRamp;
  int? _heldAtMillis;

  /// Offers one sample to the tracker.
  ///
  /// Returns whether the sample landed on the resampling grid and changed the
  /// reading. The caller uses it to publish at the grid's rate rather than at
  /// the bus rate.
  bool observe({
    required int nowMillis,
    required double? speedKmh,
    required double? drivePowerKw,
  }) {
    final last = _lastSampleMillis;
    if (last != null &&
        nowMillis - last < kSmoothnessSampleInterval.inMilliseconds) {
      return false;
    }

    // A signal the car did not publish breaks the run. Carrying the previous
    // power across the gap would charge the driver for a step nothing measured.
    if (speedKmh == null ||
        drivePowerKw == null ||
        !speedKmh.isFinite ||
        !drivePowerKw.isFinite) {
      _lastSampleMillis = nowMillis;
      _lastPowerKw = null;
      _evict(nowMillis);
      return true;
    }

    final elapsedMillis = last == null ? 0 : nowMillis - last;
    final continuous =
        last != null && elapsedMillis <= kSmoothnessMaxGap.inMilliseconds;
    final previousPower = _lastPowerKw;

    if (continuous && previousPower != null) {
      final delta = (drivePowerKw - previousPower).abs();
      _steps.add(
        _Step(
          nowMillis,
          delta <= kSmoothnessDeadbandKw ? 0 : delta,
          math.max(speedKmh, 0) * elapsedMillis / Duration.millisecondsPerHour,
        ),
      );
    }

    _lastSampleMillis = nowMillis;
    _lastPowerKw = drivePowerKw;
    _evict(nowMillis);
    _remember(nowMillis, speedKmh);
    return true;
  }

  /// Drops everything. Used when sampling pauses, because the power difference
  /// across a pause describes nothing the driver did.
  void reset() {
    _steps.clear();
    _lastSampleMillis = null;
    _lastPowerKw = null;
    _heldStanding = null;
    _heldRamp = null;
    _heldAtMillis = null;
  }

  void _evict(int nowMillis) {
    final cutoff = nowMillis - kSmoothnessWindow.inMilliseconds;
    while (_steps.isNotEmpty && _steps.first.atMillis < cutoff) {
      _steps.removeFirst();
    }
  }

  /// Keeps the newest standing measured **while moving**, so a stop can hold
  /// it.
  ///
  /// The movement gate is load-bearing rather than tidy. As a car comes to a
  /// stop the window keeps the ramp of the deceleration while its distance
  /// drains away, so the ratio climbs steeply for the few seconds before the
  /// reading is withdrawn. Latching in that stretch caught the worst value of
  /// the whole drive and held it through the red light: a driver who had been
  /// smooth for a minute watched the pill fall to amber for stopping, which is
  /// the same class of defect as the reading this replaced. Only a sample taken
  /// while the car is actually moving describes driving.
  void _remember(int nowMillis, double speedKmh) {
    if (speedKmh < kSmoothnessMinSpeedKmh) return;
    final ramp = _rampOver(kSmoothnessWindow, nowMillis);
    if (ramp == null) return;
    _heldRamp = ramp;
    _heldStanding = smoothnessScore(ramp, reference: reference);
    _heldAtMillis = nowMillis;
  }

  /// Ramp per kilometre over the trailing [width], or null when the window did
  /// not cover enough distance to divide by.
  double? _rampOver(Duration width, int nowMillis) {
    final cutoff = nowMillis - width.inMilliseconds;
    var ramp = 0.0;
    var distanceKm = 0.0;
    for (final step in _steps) {
      if (step.atMillis < cutoff) continue;
      ramp += step.rampKw;
      distanceKm += step.distanceKm;
    }
    if (distanceKm < smoothnessDistanceFloorKm(width)) return null;
    return ramp / distanceKm;
  }

  /// The reading as of [nowMillis].
  ///
  /// Takes the clock rather than storing it, so a caller that has stopped
  /// sampling still gets a reading that ages — a held value must expire on the
  /// wall clock, not on the next sample that may never arrive.
  DrivingSmoothness readingAt(int nowMillis) {
    final ramp = _rampOver(kSmoothnessWindow, nowMillis);
    final instantRamp = _rampOver(kSmoothnessInstantWindow, nowMillis);
    final instant = instantRamp == null
        ? null
        : smoothnessScore(instantRamp, reference: reference);

    if (ramp != null) {
      return DrivingSmoothness(
        state: SmoothnessState.measured,
        standing: smoothnessScore(ramp, reference: reference),
        instant: instant,
        rampKwPerKm: ramp,
      );
    }

    final held = _heldStanding;
    final heldAt = _heldAtMillis;
    if (held != null &&
        heldAt != null &&
        nowMillis - heldAt <= kSmoothnessHold.inMilliseconds) {
      return DrivingSmoothness(
        state: SmoothnessState.held,
        standing: held,
        // No instant mark while stopped. The car is not being driven, so there
        // is no "now" to compare the standing against.
        rampKwPerKm: _heldRamp,
      );
    }
    return DrivingSmoothness.unavailable;
  }
}
