part of 'telemetry_dto.dart';

/// What the driver asked the climate system for over a session.
///
/// Demand, never energy. The calibrated climate power exists on the car but
/// never becomes a frame column — what is stored is the raw count, so nothing
/// that syncs to the phone can be turned into watt-hours. This says whether the
/// system ran, which way it was working and how hard it was asked to work, and
/// it stops there.
///
/// The energy it drew is real and is already counted: it sits inside the
/// auxiliary remainder, unnamed. That is what makes this a companion to the
/// energy balance rather than a division of it.
class ClimateDemand {
  const ClimateDemand({
    required this.reportingFrames,
    required this.onFrames,
    required this.compressorFrames,
    required this.meanBlowerLevel,
    required this.maxBlowerLevel,
    required this.meanSetpointC,
  });

  /// Frames on which the car said whether climate was on. Frames where it said
  /// nothing are not counted as "off": a controller that went quiet and a
  /// system that was idle are different facts.
  final int reportingFrames;

  final int onFrames;

  /// Frames with the compressor running, counted only while climate was on.
  /// It is what separates cooling from heating, and it is the one split the
  /// 2026-08-08 bench could hold.
  final int compressorFrames;

  /// Over the frames climate was on, so a long stop with the system off does
  /// not drag the level towards zero.
  final double? meanBlowerLevel;
  final int? maxBlowerLevel;
  final double? meanSetpointC;

  /// Share of the reported session the system ran, 0 to 1.
  double get onShare => reportingFrames <= 0 ? 0 : onFrames / reportingFrames;

  /// Whether the compressor ran for most of the time the system was on.
  ///
  /// Null when nothing reported the compressor, and null for a session that
  /// split evenly enough that neither word describes it — an hour of cooling
  /// followed by an hour of heating is not "cooling".
  bool? get wasCooling {
    if (onFrames <= 0) return null;
    final share = compressorFrames / onFrames;
    if (share >= _decisiveShare) return true;
    if (share <= 1 - _decisiveShare) return false;
    return null;
  }

  /// How one-sided the compressor has to be before a session is named by it.
  static const _decisiveShare = 0.8;
}

/// The duration of a synced trip row, derived from its endpoints.
///
/// Only for a closed session. An open one has no end stamped, and the car fills
/// that in with its own clock — which a phone cannot do, because the elapsed
/// stamp belongs to the car's boot and the wall stamp to the car's clock.
/// Answering with the phone's "now" would measure the two devices against each
/// other.
int? _tripDurationFromRow(Map<String, Object?> map) {
  final endUtcMillis = _asInt(map['endedAtUtcMillis']);
  final endElapsedNanos = _asInt(map['endedAtElapsedNanos']);
  if (endUtcMillis == null || endElapsedNanos == null) return null;
  return sessionDurationMillis(
    startUtcMillis: _asInt(map['startedAtUtcMillis']) ?? 0,
    startElapsedNanos: _asInt(map['startedAtElapsedNanos']) ?? 0,
    startBootCount: _asInt(map['startedAtBootCount']),
    endUtcMillis: endUtcMillis,
    endElapsedNanos: endElapsedNanos,
    endBootCount: _asInt(map['endedAtBootCount']),
    maxWallDurationMillis: kMaxTripWallDurationMillis,
  );
}

/// The duration of a synced charge row, derived from its endpoints.
///
/// The ends are the ones the car reconciles with: charging start falls back to
/// the plug going in, and the end falls back from unplugged to charging ended.
/// A row with neither end stamped is an open session and is left undecided.
int? _chargeDurationFromRow(Map<String, Object?> map) {
  final startUtcMillis =
      _asInt(map['chargeStartedAtUtcMillis']) ??
      _asInt(map['plugConnectedAtUtcMillis']) ??
      _asInt(map['startedAtUtcMillis']);
  final startElapsedNanos =
      _asInt(map['chargeStartedAtElapsedNanos']) ??
      _asInt(map['plugConnectedAtElapsedNanos']) ??
      _asInt(map['startedAtElapsedNanos']);
  final startBootCount =
      _asInt(map['chargeStartedAtBootCount']) ??
      _asInt(map['plugConnectedAtBootCount']) ??
      _asInt(map['startedAtBootCount']);
  final endUtcMillis =
      _asInt(map['plugDisconnectedAtUtcMillis']) ??
      _asInt(map['chargeEndedAtUtcMillis']) ??
      _asInt(map['endedAtUtcMillis']);
  final endElapsedNanos =
      _asInt(map['plugDisconnectedAtElapsedNanos']) ??
      _asInt(map['chargeEndedAtElapsedNanos']) ??
      _asInt(map['endedAtElapsedNanos']);
  final endBootCount =
      _asInt(map['plugDisconnectedAtBootCount']) ??
      _asInt(map['chargeEndedAtBootCount']) ??
      _asInt(map['endedAtBootCount']);
  if (startUtcMillis == null ||
      startElapsedNanos == null ||
      endUtcMillis == null ||
      endElapsedNanos == null) {
    return null;
  }
  return sessionDurationMillis(
    startUtcMillis: startUtcMillis,
    startElapsedNanos: startElapsedNanos,
    startBootCount: startBootCount,
    endUtcMillis: endUtcMillis,
    endElapsedNanos: endElapsedNanos,
    endBootCount: endBootCount,
    maxWallDurationMillis: kMaxChargeWallDurationMillis,
  );
}
