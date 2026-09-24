import 'package:flutter/foundation.dart';

import 'telemetry_api.dart';

/// Single source of truth for programmatic / external navigation requests
/// (such as opening the app when charging begins).
///
/// The request arrives by two routes, and both are needed. A warm start is a
/// push from the bridge, which Flutter is already listening for. A cold start
/// happens before `main()` runs, so nothing is listening and the push is lost;
/// [loadPending] reads what the native side kept instead.
class AppNavigationController extends ChangeNotifier {
  AppNavigationController._();

  static final AppNavigationController instance = AppNavigationController._();

  /// The destinations something outside the app asks for. Each one replaces a
  /// factory screen this app suppresses, and each must match the id the shell
  /// uses and the id `AutoOpenLauncher` sends.
  static const String charging = 'charging';
  static const String carplay = 'carplay';
  static const String androidAuto = 'androidAuto';

  String? _pendingDestination;

  /// The current pending destination requested from outside, e.g. `'charging'`.
  String? get pendingDestination => _pendingDestination;

  /// Requests navigation to a specific destination tab.
  void navigateTo(String destination) {
    _pendingDestination = destination;
    notifyListeners();
  }

  /// Clears the pending destination once handled by the active shell.
  void clearPending() {
    _pendingDestination = null;
  }

  /// Reads the destination the app was launched for, if any.
  ///
  /// A failed read is not a destination: the app simply opens where it always
  /// does, so the error is swallowed rather than shown.
  Future<void> loadPending(TelemetryApi api) async {
    try {
      final destination = await api.takePendingDestination();
      if (destination != null) navigateTo(destination);
    } catch (_) {
      // No destination. Nothing to report.
    }
  }
}
