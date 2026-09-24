import 'dart:async';

import 'package:flutter/foundation.dart';

import 'telemetry_api.dart';

enum VehicleChargingActivity { unknown, notCharging, charging }

/// Process-wide vehicle state for UI surfaces that need shared status.
///
/// The controller treats missing and failed readings as unknown. It does not
/// keep a stale charging value after a refresh failure.
class VehicleStateController extends ChangeNotifier {
  VehicleStateController({
    TelemetryApi? telemetryApi,
    this.refreshInterval = const Duration(seconds: 5),
  }) : _telemetryApi = telemetryApi ?? TelemetryApi.shared;

  static final VehicleStateController instance = VehicleStateController();

  final TelemetryApi _telemetryApi;
  final Duration refreshInterval;

  late final PollLoop _loop = PollLoop(
    interval: refreshInterval,
    read: _read,
    debugLabel: 'VehicleStateController',
  );
  TelemetrySnapshot? _snapshot;
  VehicleChargingActivity _chargingActivity = VehicleChargingActivity.unknown;

  TelemetrySnapshot? get snapshot => _snapshot;

  /// The odometer the car last reported, or null when it did not report one.
  ///
  /// A reading the car marked unusable is null here rather than its raw value:
  /// a caller measuring a distance between two odometer reads must not treat a
  /// rejected one as a position.
  double? get odometerKm {
    final reading = _snapshot?.odometerKm;
    if (reading == null || !reading.ok) return null;
    return reading.value;
  }

  VehicleChargingActivity get chargingActivity => _chargingActivity;
  bool get isActivelyCharging =>
      _chargingActivity == VehicleChargingActivity.charging;

  void start() => _loop.start();

  void stop() => _loop.stop();

  /// Reads once, unless the loop already has a read in flight.
  Future<void> refresh() => _loop.runNow();

  Future<void> _read() async {
    try {
      final snapshot = await _telemetryApi.getTelemetrySnapshot();
      _applySnapshot(snapshot);
      notifyListeners();
    } catch (_) {
      final hadSnapshot = _snapshot != null;
      _snapshot = null;
      final activityChanged = _setChargingActivity(
        VehicleChargingActivity.unknown,
      );
      // A failed read that was already unknown with no snapshot is not news.
      if (hadSnapshot || activityChanged) notifyListeners();
    }
  }

  void _applySnapshot(TelemetrySnapshot snapshot) {
    _snapshot = snapshot;
    final charging = snapshot.charging;
    _setChargingActivity(
      charging.ok && charging.isCharging != null
          ? charging.isCharging!
                ? VehicleChargingActivity.charging
                : VehicleChargingActivity.notCharging
          : VehicleChargingActivity.unknown,
    );
    // An applied read carries new measurements (SOC, power, speed) even when
    // the charging activity is unchanged, so listeners are notified exactly
    // once per read — never twice, and never for a no-op.
    notifyListeners();
  }

  /// Stores [value] without notifying. Returns true when it actually changed.
  bool _setChargingActivity(VehicleChargingActivity value) {
    if (_chargingActivity == value) return false;
    _chargingActivity = value;
    return true;
  }

  @visibleForTesting
  void applySnapshotForTest(TelemetrySnapshot snapshot) {
    _applySnapshot(snapshot);
  }

  @visibleForTesting
  void reset() {
    stop();
    _snapshot = null;
    _chargingActivity = VehicleChargingActivity.unknown;
    notifyListeners();
  }
}
