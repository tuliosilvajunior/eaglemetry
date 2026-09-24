import 'dart:async';

import 'package:flutter/foundation.dart';

import 'telemetry_api.dart';

/// Shares the vehicle-range and app-range estimate process-wide.
///
/// Every 2 seconds it polls [TelemetryApi.getRangeEstimate]; the native side
/// answers from the signal-state store and an in-memory efficiency cache, never
/// from the database, so the cadence is cheap. A failed poll keeps the last
/// successful DTO for up to [staleWindow] with [hasFailed] true; past that the
/// controller exposes unavailable values instead of a stale estimate.
class RangeEstimateController extends ChangeNotifier {
  RangeEstimateController({
    TelemetryApi? telemetryApi,
    this.pollInterval = const Duration(seconds: 2),
  }) : _telemetryApi = telemetryApi ?? TelemetryApi.shared;

  static final RangeEstimateController instance = RangeEstimateController();

  /// How long the last successful DTO may be shown after a poll stops landing.
  static const staleWindow = Duration(seconds: 10);

  final TelemetryApi _telemetryApi;
  final Duration pollInterval;

  late final PollLoop _loop = PollLoop(
    interval: pollInterval,
    read: _read,
    debugLabel: 'RangeEstimateController',
  );
  RangeEstimate? _estimate;
  DateTime? _lastSuccessAt;
  bool _lastPollFailed = false;
  DateTime Function() _clock = DateTime.now;

  /// The last successful DTO while it is still current, null otherwise.
  RangeEstimate? get estimate {
    final last = _lastSuccessAt;
    if (last == null) return null;
    if (_clock().difference(last) > staleWindow) return null;
    return _estimate;
  }

  /// True while the most recent poll failed and no newer poll has succeeded.
  bool get hasFailed => _lastPollFailed;

  /// The validated full-range factor (capacity x efficiency), or null.
  double? get fullRangeKm {
    final full = estimate?.fullRangeKm;
    if (full == null || !full.isFinite || full < 0) return null;
    return full;
  }

  void start() => _loop.start();

  void stop() => _loop.stop();

  /// Reads once, unless the loop already has a read in flight.
  Future<void> refresh() => _loop.runNow();

  Future<void> _read() async {
    try {
      final value = await _telemetryApi.getRangeEstimate();
      _estimate = value;
      _lastSuccessAt = _clock();
      _lastPollFailed = false;
      notifyListeners();
    } catch (_) {
      // Keep the last good DTO within its staleness window; the getters decide
      // when it becomes unavailable. A failed poll is not the same as the car
      // having no data, and hasFailed lets the UI say which one happened.
      _lastPollFailed = true;
      notifyListeners();
    }
  }

  /// Projects range at a target SOC from the native full-range factor.
  ///
  /// The native side has already validated capacity and efficiency; this only
  /// scales the factor and rejects an out-of-domain target. A non-finite full
  /// range or target yields null.
  double? kilometersAt(double socPercent) {
    if (!socPercent.isFinite || socPercent < 0 || socPercent > 100) return null;
    final full = fullRangeKm;
    if (full == null) return null;
    final result = socPercent / 100 * full;
    if (!result.isFinite || result < 0) return null;
    return result;
  }

  @visibleForTesting
  void setClockForTest(DateTime Function() clock) {
    _clock = clock;
  }

  @visibleForTesting
  void reset() {
    stop();
    _estimate = null;
    _lastSuccessAt = null;
    _lastPollFailed = false;
    notifyListeners();
  }
}
