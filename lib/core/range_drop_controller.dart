import 'package:flutter/foundation.dart';

import 'telemetry_api.dart';

/// Minimum absolute car-range drop before the panel prints figures.
///
/// Zero on purpose: the panel is being taken to the car to find out how short
/// stretches behave before a real floor is chosen. Raise it once the field data
/// says where the rounding of the dashboard's whole-kilometre readout stops
/// dominating the comparison.
const double kRangeDropFloorKm = 0;

/// One source's share of a stretch: what it spent, or why it cannot say.
///
/// Exactly one of [km] and [reason] carries the answer. The car and the app are
/// judged by the same rule and reported through the same type, which is what
/// keeps the comparison fair — a line the panel can print for one source and
/// not the other would be a difference in bookkeeping, not in the vehicle.
@immutable
class RangeDropLine {
  const RangeDropLine.measured(double this.km, {this.reason});

  const RangeDropLine.unavailable(this.reason) : km = null;

  /// Signed: positive is range consumed, negative is range recovered.
  final double? km;

  /// The native reason code the panel shows under the line: why there is no
  /// figure, or why the figure it does have is a degraded one.
  final String? reason;

  bool get isAvailable => km != null;

  /// Whether the source recovered range over the stretch.
  bool get isGain => km != null && km! < 0;
}

/// What the Range Drop panel draws.
///
/// Nothing here is a ratio or a verdict — the panel prints the three quantities
/// and the reader compares them.
@immutable
class RangeDropState {
  const RangeDropState({
    this.hasBaseline = false,
    this.baselineAt,
    this.distanceKm = 0,
    this.car = const RangeDropLine.unavailable(null),
    this.app = const RangeDropLine.unavailable(null),
    this.frozen = false,
    this.floorCleared = false,
  });

  /// Whether a start point was captured. Until then there is no stretch.
  final bool hasBaseline;

  /// When the stretch started — the moment the app began watching, which is
  /// not the start of the trip when the app joined it late.
  final DateTime? baselineAt;

  /// Odometer distance covered since [baselineAt].
  final double distanceKm;

  final RangeDropLine car;
  final RangeDropLine app;

  /// The vehicle left the trip and these figures no longer advance.
  final bool frozen;

  /// The stretch is long enough for the figures to mean anything.
  final bool floorCleared;

  RangeDropState copyWith({bool? frozen}) => RangeDropState(
    hasBaseline: hasBaseline,
    baselineAt: baselineAt,
    distanceKm: distanceKm,
    car: car,
    app: app,
    frozen: frozen ?? this.frozen,
    floorCleared: floorCleared,
  );
}

/// Measures how much promised range each source spends per kilometre driven.
///
/// It holds the start of the stretch in memory and nothing else: no Room row,
/// no annotation, no sync. A process death loses the stretch, which is why the
/// state always carries [RangeDropState.baselineAt] — the panel has to say
/// which stretch it is reporting, or the figures read as a claim about the
/// whole trip.
///
/// The controller runs no poll of its own. It reads through the closures it is
/// given and advances on [source], which is the notification the polls the
/// screen already runs emit anyway.
class RangeDropController extends ChangeNotifier {
  RangeDropController({
    required this.source,
    required this.readEstimate,
    required this.readOdometerKm,
    required this.readActiveSessionId,
    DateTime Function()? clock,
    this.floorKm = kRangeDropFloorKm,
  }) : _clock = clock ?? DateTime.now {
    source.addListener(_observe);
  }

  /// Fires when any of the polls behind the reads below has new values.
  final Listenable source;
  final RangeEstimate? Function() readEstimate;
  final double? Function() readOdometerKm;

  /// The trip being accumulated, or null when the vehicle is not in one. It is
  /// the trip's identity as well as its presence, so a stretch cannot survive
  /// into the next drive.
  final String? Function() readActiveSessionId;
  final DateTime Function() _clock;

  /// See [kRangeDropFloorKm]. Injected only so a test can state a real floor.
  final double floorKm;

  String? _sessionId;
  DateTime? _baselineAt;
  double? _baselineOdometerKm;
  double? _baselineCarRangeKm;
  double? _baselineAppRangeKm;
  RangeDropState _state = const RangeDropState();

  RangeDropState get state => _state;

  @override
  void dispose() {
    source.removeListener(_observe);
    super.dispose();
  }

  void _observe() {
    final sessionId = readActiveSessionId();

    // No trip: hold whatever the last stretch reported, so the figures survive
    // the stop and can be read after the drive. A trip that never produced a
    // stretch has nothing to freeze.
    if (sessionId == null) {
      if (_state.hasBaseline && !_state.frozen) {
        _publish(_state.copyWith(frozen: true));
      }
      return;
    }

    if (sessionId != _sessionId) {
      _sessionId = sessionId;
      _clearBaseline();
      _publish(const RangeDropState());
    }

    final estimate = readEstimate();
    final odometerKm = readOdometerKm();

    if (_baselineAt == null) {
      _tryCapture(estimate, odometerKm);
      return;
    }

    _publish(_measure(estimate, odometerKm));
  }

  /// A stretch starts only once every input is usable at the same tick.
  ///
  /// Half a baseline would be worse than none: a start point missing the car
  /// value would give the app a stretch the car was never measured over.
  void _tryCapture(RangeEstimate? estimate, double? odometerKm) {
    if (estimate == null || odometerKm == null) return;
    final carRangeKm = _usableCarRangeKm(estimate);
    final appRangeKm = _usableAppRangeKm(estimate);
    if (carRangeKm == null || appRangeKm == null) return;

    _baselineAt = _clock();
    _baselineOdometerKm = odometerKm;
    _baselineCarRangeKm = carRangeKm;
    _baselineAppRangeKm = appRangeKm;
    _publish(_measure(estimate, odometerKm));
  }

  RangeDropState _measure(RangeEstimate? estimate, double? odometerKm) {
    // A dropped odometer read holds the distance where it was rather than
    // collapsing the stretch to zero; the drops are still measured against the
    // same baseline, so the three figures stay from one stretch.
    final distanceKm = odometerKm == null
        ? _state.distanceKm
        : odometerKm - _baselineOdometerKm!;

    final car = _line(
      _usableCarRangeKm(estimate),
      _baselineCarRangeKm!,
      estimate?.carRangeReason,
      degraded: false,
    );
    final app = _line(
      _usableAppRangeKm(estimate),
      _baselineAppRangeKm!,
      estimate?.ownRangeReason,
      degraded: estimate?.ownRangeDegraded ?? false,
    );

    return RangeDropState(
      hasBaseline: true,
      baselineAt: _baselineAt,
      distanceKm: distanceKm,
      car: car,
      app: app,
      // The floor is a question about the car's drop, because that is the
      // figure the dashboard rounds to whole kilometres. A stretch whose car
      // line is out keeps whatever the last tick decided, so a dropped signal
      // does not take the figures off the screen and put them back.
      floorCleared: car.km == null
          ? _state.floorCleared
          : car.km!.abs() >= floorKm,
    );
  }

  RangeDropLine _line(
    double? current,
    double baseline,
    String? reason, {
    required bool degraded,
  }) => current == null
      ? RangeDropLine.unavailable(reason)
      : RangeDropLine.measured(
          baseline - current,
          reason: degraded ? reason : null,
        );

  double? _usableCarRangeKm(RangeEstimate? estimate) =>
      estimate != null && estimate.carRangeAvailable
      ? estimate.carRangeKm
      : null;

  /// The app value under the same rule as the car's.
  ///
  /// A degraded estimate counts: the efficiency behind it is the last valid
  /// one, and the panel still shows its reason. What is refused is an
  /// unavailable value, exactly as on the car side.
  double? _usableAppRangeKm(RangeEstimate? estimate) =>
      estimate != null &&
          (estimate.ownRangeAvailable || estimate.ownRangeDegraded)
      ? estimate.ownRangeKm
      : null;

  void _clearBaseline() {
    _baselineAt = null;
    _baselineOdometerKm = null;
    _baselineCarRangeKm = null;
    _baselineAppRangeKm = null;
  }

  void _publish(RangeDropState state) {
    _state = state;
    notifyListeners();
  }
}
