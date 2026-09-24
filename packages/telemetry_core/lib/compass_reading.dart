/// What the compass may show, from a series of GNSS course readings.
///
/// A single [HeadingReading] cannot answer this. The receiver reports a course
/// only while the vehicle moves, and it reports one long before the movement is
/// real enough to trust: a car creeping in a car park produces a course that
/// swings through every point of the circle. So the compass needs two things a
/// lone reading does not have — a movement floor with memory, so the needle
/// does not flicker at a red light, and a decision about how long a heading
/// stays true after the car stops.
///
/// [CompassTracker] holds that memory. It is a pure fold: readings and a clock
/// go in, a [CompassReading] comes out. Nothing here draws, and nothing here
/// talks to the bridge.
library;

import 'dart:math' as math;

import 'dto/telemetry_dto.dart';

/// Speed at which a course becomes trustworthy. 3 km/h.
///
/// Below walking pace the GNSS course over ground is derived from a
/// displacement close to the position error, so it points nowhere in
/// particular.
const double kCompassShowFloorKmh = 3.0;

/// Speed at which a trusted course stops being updated. 1.5 km/h.
///
/// Lower than [kCompassShowFloorKmh] on purpose. One floor would make the
/// needle appear and vanish repeatedly in stop-and-go traffic, which is worse
/// than either state alone.
const double kCompassKeepFloorKmh = 1.5;

/// How far the car may creep before a held heading is discarded. 5 metres.
///
/// A held heading assumes the car has not turned since it stopped. That
/// assumption is not a matter of time — a car can stand for an hour and still
/// face the same way — but of movement. Five metres passes any manoeuvre that
/// could have turned the car, and no amount of waiting at a light.
const double kCompassCreepLimitM = 5.0;

/// Weight of a new course against the one on screen. 0.25.
///
/// Applied on the shortest arc, never on the raw numbers: the mean of 359 and 1
/// degrees is 180, which points the needle backwards.
const double kCompassSmoothing = 0.25;

double _kmhToMps(double kmh) => kmh / 3.6;

/// What the compass is showing.
enum CompassState {
  /// The car is moving and the course is current.
  live,

  /// The car has stopped. The last trusted course is held, on the assumption
  /// that a stationary car still faces the way it arrived.
  held,

  /// There is nothing to show. [CompassReading.reason] says why.
  unavailable,
}

/// One reading of the compass.
class CompassReading {
  const CompassReading({
    required this.state,
    required this.bearingDeg,
    required this.reason,
    required this.heldForMillis,
  });

  /// Nothing to show yet, for the reason the source gave.
  const CompassReading.unavailable(HeadingAvailability reason)
    : this(
        state: CompassState.unavailable,
        bearingDeg: null,
        reason: reason,
        heldForMillis: 0,
      );

  final CompassState state;

  /// The direction of travel, 0 up to but not including 360 degrees.
  ///
  /// Null exactly when [state] is [CompassState.unavailable]. It is a course
  /// over ground, so in reverse it points the opposite way to the vehicle.
  final double? bearingDeg;

  /// Why the source had no course at this reading, whatever [state] is. It
  /// stays readable while a heading is held, because that is what names the
  /// hold: [HeadingAvailability.noBearing] is a car that stopped.
  final HeadingAvailability reason;

  /// How long the held course has been held. Zero unless [state] is
  /// [CompassState.held].
  final int heldForMillis;

  /// True when the app may draw a needle.
  bool get hasBearing => bearingDeg != null;
}

/// Turns a series of [HeadingReading] into what a compass may draw.
///
/// Feed it every reading, in order, with [update]. It keeps one heading and one
/// creep total, and nothing else.
class CompassTracker {
  CompassTracker({
    double showFloorKmh = kCompassShowFloorKmh,
    double keepFloorKmh = kCompassKeepFloorKmh,
    // The floors arrive in km/h and are converted; these two are already in the
    // unit the tracker works in.
    this._creepLimitM = kCompassCreepLimitM,
    this._smoothing = kCompassSmoothing,
  }) : assert(keepFloorKmh <= showFloorKmh, 'the keep floor is the lower one'),
       _showFloorMps = _kmhToMps(showFloorKmh),
       _keepFloorMps = _kmhToMps(keepFloorKmh);

  final double _showFloorMps;
  final double _keepFloorMps;
  final double _creepLimitM;
  final double _smoothing;

  double? _bearingDeg;
  bool _moving = false;
  double _creepM = 0;
  int? _lastMillis;
  int? _heldSinceMillis;

  /// The last reading [update] produced. Unavailable before the first one.
  CompassReading get reading => _reading;
  CompassReading _reading = const CompassReading.unavailable(
    HeadingAvailability.noFix,
  );

  /// Folds one reading in and answers what the compass may now show.
  ///
  /// [nowMillis] is the clock the hold is measured against. It defaults to the
  /// reading's own timestamp, which is what the native side stamped.
  CompassReading update(HeadingReading heading, {int? nowMillis}) {
    final now = nowMillis ?? heading.timestampMillis;
    final elapsedMillis = _lastMillis == null
        ? 0
        : math.max(0, now - _lastMillis!);
    _lastMillis = now;

    // Only a stopped car earns a hold. Every other refusal is a fault or a
    // setting, and none of them says the car stayed where it was: a lost fix in
    // a tunnel is a car still travelling, and holding a heading through it
    // would be a claim nothing measured.
    if (heading.availability != HeadingAvailability.ok &&
        heading.availability != HeadingAvailability.noBearing) {
      return _reset(heading.availability);
    }

    final speed = heading.speedMps;
    final bearing = heading.bearingDeg;
    if (bearing != null && speed != null && speed >= _floorFor(_moving)) {
      _moving = true;
      _creepM = 0;
      _heldSinceMillis = null;
      _bearingDeg = _bearingDeg == null
          ? bearing
          : _blend(_bearingDeg!, bearing, _smoothing);
      return _reading = CompassReading(
        state: CompassState.live,
        bearingDeg: _bearingDeg,
        reason: heading.availability,
        heldForMillis: 0,
      );
    }

    // Below the floor. The course is no longer taken, but the movement still
    // counts against the held heading: what invalidates a hold is the car
    // turning, and a slow manoeuvre turns it just as far as a fast one.
    _moving = false;
    if (_bearingDeg == null) {
      return _reading = CompassReading.unavailable(heading.availability);
    }
    _creepM += (speed ?? 0) * elapsedMillis / 1000;
    if (_creepM > _creepLimitM) {
      return _reset(heading.availability);
    }
    _heldSinceMillis ??= now;
    return _reading = CompassReading(
      state: CompassState.held,
      bearingDeg: _bearingDeg,
      reason: heading.availability,
      heldForMillis: math.max(0, now - _heldSinceMillis!),
    );
  }

  /// Forgets the held heading. Call it when the reader stops watching, so a
  /// stale course cannot reappear on the next screen that looks.
  void reset() {
    _reset(HeadingAvailability.noFix);
    _lastMillis = null;
  }

  CompassReading _reset(HeadingAvailability reason) {
    _bearingDeg = null;
    _moving = false;
    _creepM = 0;
    _heldSinceMillis = null;
    return _reading = CompassReading.unavailable(reason);
  }

  /// The floor to apply now. A course already on screen is kept on the lower
  /// one; a new course has to pass the higher one.
  double _floorFor(bool moving) => moving ? _keepFloorMps : _showFloorMps;
}

/// Moves [from] a fraction [weight] of the way to [to], the short way round.
///
/// Interpolating the plain numbers crosses the whole dial whenever the pair
/// straddles north.
double compassBlend(double from, double to, double weight) =>
    _blend(from, to, weight);

double _blend(double from, double to, double weight) =>
    _normalize(from + compassDelta(from, to) * weight);

/// The turn from [from] to [to], negative to the left, in -180 up to 180.
double compassDelta(double from, double to) {
  final delta = (_normalize(to) - _normalize(from) + 540.0) % 360.0 - 180.0;
  // A delta of exactly -180 and one of 180 are the same turn. Reporting the
  // positive one keeps a half-turn from flipping sign between readings.
  return delta == -180.0 ? 180.0 : delta;
}

/// Folds any angle into 0 degrees up to, but not including, 360.
///
/// Public because the needle simulation integrates past both ends of the dial
/// and has to fold the result. A second copy of this would be a second place
/// for the sign of the modulo to be got wrong.
double compassNormalize(double value) {
  final wrapped = value % 360.0;
  return wrapped < 0 ? wrapped + 360.0 : wrapped;
}

double _normalize(double value) => compassNormalize(value);

/// The compass course, as a whole degree of the dial.
///
/// 360 folds back to 0: they are the same direction, and a compass that can
/// print both has two names for north.
String compassBearingLabel(double? degrees) {
  if (degrees == null || !degrees.isFinite) return '--';
  return '${degrees.round() % 360}°';
}
