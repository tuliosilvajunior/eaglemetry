/// How long a session lasted, from the two clocks that stamped its ends.
///
/// This mirrors `SessionTimeReconciler.canonicalDurationMillis` in Kotlin. It
/// exists in Dart because the sync sends a session's stored row, and that row
/// holds the endpoints rather than the duration: the duration is derived, and
/// on the car it is derived by the repository that answers Flutter. A phone
/// that only had the row printed `--` for every session until this existed.
///
/// `testdata/session_duration_cases.json` is the specification both languages
/// read, so a failure states that the rule moved rather than that one side
/// moved first.
library;

/// The longest wall-clock span accepted for a drive, when the monotonic clock
/// cannot answer. Mirrors `MAX_TRIP_WALL_DURATION_MILLIS`.
const kMaxTripWallDurationMillis = 48 * 60 * 60 * 1000;

/// Mirrors `MAX_CHARGE_WALL_DURATION_MILLIS`. Far longer than a drive, because
/// a car can sit plugged in for weeks.
const kMaxChargeWallDurationMillis = 31 * 24 * 60 * 60 * 1000;

/// The monotonic span between two stamps, or null when it cannot be trusted.
///
/// Null unless both ends name the same boot. Elapsed realtime restarts at a
/// reboot, so a span across two boots is not a span at all — it is the second
/// boot's clock minus the first's, which measures nothing.
int? monotonicDurationMillis({
  required int startElapsedNanos,
  required int? startBootCount,
  required int endElapsedNanos,
  required int? endBootCount,
}) {
  if (startBootCount == null ||
      endBootCount == null ||
      startBootCount != endBootCount) {
    return null;
  }
  final deltaNanos = endElapsedNanos - startElapsedNanos;
  if (startElapsedNanos <= 0 || deltaNanos < 0) return null;
  const nanosPerMillisecond = 1000000;
  return (deltaNanos + nanosPerMillisecond ~/ 2) ~/ nanosPerMillisecond;
}

/// How long the session lasted, or null when neither clock can say.
///
/// The monotonic clock is preferred and is not merely a tie-breaker: it is the
/// only one that measures elapsed time. The wall clock steps when the car
/// corrects it, so a drive can appear to last minus twenty minutes.
///
/// The wall clock is the fallback, bounded by [maxWallDurationMillis]. A span
/// outside that band is not a long session, it is a corrupt stamp — and null,
/// so a reader prints a dash instead of a week-long drive.
int? sessionDurationMillis({
  required int startUtcMillis,
  required int startElapsedNanos,
  required int? startBootCount,
  required int endUtcMillis,
  required int endElapsedNanos,
  required int? endBootCount,
  required int maxWallDurationMillis,
}) {
  final monotonic = monotonicDurationMillis(
    startElapsedNanos: startElapsedNanos,
    startBootCount: startBootCount,
    endElapsedNanos: endElapsedNanos,
    endBootCount: endBootCount,
  );
  if (monotonic != null) return monotonic;

  final wall = endUtcMillis - startUtcMillis;
  if (wall < 0 || wall > maxWallDurationMillis) return null;
  return wall;
}
