import 'package:flutter/widgets.dart';

import 'telemetry_api.dart';

/// The one place the app decides which [TelemetryApi] a screen talks to.
///
/// Sixteen widgets and controllers each wrote `TelemetryApi()`. The object is
/// cheap, so that cost nothing at runtime — the fault is that no single place
/// decided what a screen talks to. Choosing a different implementation, for a
/// mock run or for a bench harness, meant editing sixteen files and hoping none
/// was missed.
///
/// [TelemetryApi.shared] is what the app uses. This widget exists to put a
/// different instance under a subtree, which is what a widget test needs and
/// what the transport split will need when the channel and the mock become two
/// implementations chosen at startup.
class TelemetryScope extends InheritedWidget {
  const TelemetryScope({required this.api, required super.child, super.key});

  final TelemetryApi api;

  /// The api for [context], or [TelemetryApi.shared] when no scope is above it.
  ///
  /// This reads the scope without depending on it, so it is safe to call from
  /// `initState`. Depending on it would be wrong as well as inconvenient: the
  /// api is fixed for the life of the subtree, and a screen that rebuilt
  /// because of it would be rebuilding for an event that cannot happen.
  static TelemetryApi of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TelemetryScope>()?.api ??
      TelemetryApi.shared;

  @override
  bool updateShouldNotify(TelemetryScope oldWidget) =>
      !identical(api, oldWidget.api);
}
