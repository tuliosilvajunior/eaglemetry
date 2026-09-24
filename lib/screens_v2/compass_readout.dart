import 'dart:async';

import 'package:flutter/material.dart';

import '../core/telemetry_api.dart';
import '../core/telemetry_scope.dart';
import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

/// The compass card for the shell's instant-readout strip.
///
/// The source is the GNSS course over ground. This car has no usable
/// magnetometer, so the card can only answer while the vehicle moves, and
/// [CompassTracker] is what decides when it may answer at all — the two speed
/// floors, and the hold that keeps the last course through a stop.
///
/// Like [InclineReadout] it feeds itself and stops reading when a fullscreen
/// card pushes the strip off screen. It polls at the rate the receiver
/// publishes, which is one fix per second: the native `LocationSignalProvider`
/// asks for updates at that interval, so a faster poll would return the same
/// fix repeatedly.
class CompassReadout extends StatefulWidget {
  const CompassReadout({this.stage, this.telemetryApi, super.key});

  /// The shell's card stage, watched so the card stops reading while the strip
  /// is off screen.
  final CardStageController? stage;

  /// Test seam. In production the card reads [TelemetryScope.of].
  final TelemetryApi? telemetryApi;

  @override
  State<CompassReadout> createState() => _CompassReadoutState();
}

class _CompassReadoutState extends State<CompassReadout>
    with WidgetsBindingObserver {
  /// One read per published fix.
  static const _interval = Duration(seconds: 1);

  final CompassTracker _tracker = CompassTracker();

  /// The reading the card draws. A notifier rather than `setState`, so a new
  /// course repaints the card instead of the strip above it.
  late final ValueNotifier<CompassReading> _reading =
      ValueNotifier<CompassReading>(_tracker.reading);

  late final PollLoop _loop = PollLoop(
    interval: _interval,
    read: _read,
    debugLabel: 'CompassReadout',
    // A bridge that cannot answer is not a car facing nowhere. The tracker is
    // told nothing, so it keeps whatever it held, and the next tick decides.
    onError: (error, stack) {},
  );

  TelemetryApi? _api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.stage?.addListener(_onStageChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read through the scope rather than depending on it, which is what makes
    // this safe to do outside of `build`.
    _api = widget.telemetryApi ?? TelemetryScope.of(context);
    _resume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.stage?.removeListener(_onStageChanged);
    _loop.dispose();
    _reading.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Stricter than `AppForegroundGate`, and kept for two reasons. `_pause`
    // also drops the held course, which a disarmed timer would keep and then
    // show for a car that has since turned. And the card pauses for a reason
    // the gate cannot see — a fullscreen card over the footer — so the state
    // has to live here anyway.
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else {
      _pause();
    }
  }

  void _onStageChanged() {
    if (widget.stage?.isFullscreen ?? false) {
      _pause();
    } else {
      _resume();
    }
  }

  Future<void> _read() async {
    final api = _api;
    if (api == null) return;
    final heading = await api.getHeading();
    if (!mounted) return;
    _reading.value = _tracker.update(heading);
  }

  void _resume() {
    if (!mounted || _api == null) return;
    if (widget.stage?.isFullscreen ?? false) return;
    _loop.start();
  }

  void _pause() {
    _loop.stop();
    // The held course is forgotten when the card stops watching. A car that
    // moved while nothing was reading would otherwise come back to a direction
    // it no longer faces, and the hold's own guard — distance crept — cannot
    // see movement nobody sampled.
    _tracker.reset();
    _reading.value = _tracker.reading;
  }

  /// The line under the title. Live needs none: a working reading explains
  /// itself, and a caption on it would be noise on the one state that is
  /// normal.
  String? _caption(AppLocalizations loc, CompassReading reading) {
    if (reading.state == CompassState.live) return null;
    if (reading.state == CompassState.held) return loc.compassHeld;
    return switch (reading.reason) {
      HeadingAvailability.gpsDisabled => loc.compassGpsOff,
      HeadingAvailability.permissionMissing => loc.compassNoPermission,
      _ => loc.compassNoFix,
    };
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final cardinals = [
      loc.compassNorth,
      loc.compassNortheast,
      loc.compassEast,
      loc.compassSoutheast,
      loc.compassSouth,
      loc.compassSouthwest,
      loc.compassWest,
      loc.compassNorthwest,
    ];
    return ValueListenableBuilder<CompassReading>(
      valueListenable: _reading,
      builder: (context, reading, _) => CompassCard(
        label: loc.compassReadoutTitle,
        value: compassBearingLabel(reading.bearingDeg),
        bearingDeg: reading.bearingDeg,
        cardinalLabels: cardinals,
        state: reading.state,
        caption: _caption(loc, reading),
      ),
    );
  }
}
