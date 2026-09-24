import 'package:telemetry_core/telemetry_core.dart';

/// How much of the charge the climate package is eating.
///
/// During a charge the pack reading is the charging current, and the climate
/// load is drawn from the high-voltage bus *before* the pack sensor sees it.
/// So the energy the climate spends is not an extra on top of the charge — it
/// is charge that never reached the battery. A driver preconditioning the cabin
/// on a slow charger can be paying for a full rate and storing very little of
/// it, with nothing on screen saying so.
///
/// This reads the share and nothing else. The words belong to the caller.
///
/// The climate figure behind it is a **floor** while the car is cooling. The
/// daemon decodes `VCU_ThermalPwrAct` at 0.08 kW per count, but the counter
/// misses the condenser fan and under-declares cooling by about 39 %.
/// So this warning errs towards
/// silence: it can fail to appear when it should, and it does not appear when
/// it should not. That is the right direction for an unprompted interruption,
/// and it is why the absence of the banner is not evidence of a small draw.
enum ChargeClimateWarning {
  /// The climate draw is below the share worth interrupting the driver for, or
  /// it could not be read at all. Both are silence, because a warning that
  /// cannot state a number is not a warning.
  none,

  /// The climate draw is over [kClimateShareWarn] of the charging rate, and
  /// below the whole of it. The battery still gains, more slowly than the
  /// charger suggests.
  high,

  /// The climate draw is at or above the charging rate. The pack gains nothing,
  /// and may be losing charge while plugged in.
  outweighs;

  bool get isWarning => this != ChargeClimateWarning.none;
}

/// Share of the charging rate at which the banner appears.
const double kClimateShareWarn = 0.5;

/// Share it must fall back below before the banner goes away.
///
/// A single threshold makes the banner flicker: a compressor cycling around
/// half the charge rate would show and hide it every few seconds, which reads
/// as a fault in the app rather than as a fact about the car. The gap is the
/// same device the charge-limit control uses for a value that hovers.
const double kClimateShareClear = 0.4;

/// The climate share of the charge, with the previous reading's hysteresis.
///
/// [buckets] are the open charge's minutes, which carry climate and nothing
/// else. [chargingPowerKw] is the rate the car reports it is taking in.
///
/// [previous] holds the banner steady across the gap between
/// [kClimateShareClear] and [kClimateShareWarn]; pass
/// [ChargeClimateWarning.none] for a first read.
///
/// The two terms come off different clocks on purpose. Climate is a rate over
/// the minutes in memory, and the charge rate is the instant the car published.
/// A warning wants the averaged climate: a compressor that cycles would
/// otherwise trip it on each start. The averaging is what makes the reading
/// steady, not a smoothing applied afterwards.
ChargeClimateWarning readChargeClimateWarning({
  required List<EnergyBucket> buckets,
  required double? chargingPowerKw,
  required ChargeClimateWarning previous,
}) {
  final climateKw = readChargeClimateKw(buckets);
  if (climateKw == null || climateKw <= 0) return ChargeClimateWarning.none;

  final charging = chargingPowerKw;
  if (charging == null || !charging.isFinite || charging < 0) {
    return ChargeClimateWarning.none;
  }

  // A charger delivering nothing while the climate draws is the extreme of the
  // same fact, not a division by zero. It is reported without a ratio.
  if (charging <= 0) return ChargeClimateWarning.outweighs;

  final share = climateKw / charging;
  if (share >= 1) return ChargeClimateWarning.outweighs;

  final threshold = previous.isWarning ? kClimateShareClear : kClimateShareWarn;
  return share > threshold
      ? ChargeClimateWarning.high
      : ChargeClimateWarning.none;
}

/// Mean climate draw over the buckets in hand, kW.
///
/// Total energy over total covered seconds, never the mean of the per-bucket
/// rates: the minute in progress is short by construction, and averaging rates
/// would give that partial minute the same weight as a whole one.
///
/// Null when nothing was covered. That is not a zero draw — it is a bus that
/// said nothing, which on this car is also what an uncalibrated climate signal
/// looks like.
double? readChargeClimateKw(List<EnergyBucket> buckets) {
  var wh = 0.0;
  var seconds = 0.0;
  for (final bucket in buckets) {
    if (bucket.climateIntegratedSeconds <= 0) continue;
    wh += bucket.climateWh;
    seconds += bucket.climateIntegratedSeconds;
  }
  if (seconds <= 0) return null;
  final kw = wh / seconds * 3.6;
  return kw.isFinite ? kw : null;
}
