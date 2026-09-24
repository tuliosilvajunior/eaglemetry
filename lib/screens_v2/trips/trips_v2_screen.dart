import 'package:flutter/material.dart';

import '../../core/energy_monitor_controller.dart';
import '../../core/telemetry_api.dart';
import 'package:capy_ui/capy_ui.dart';
import '../energy_session_panel.dart';

import 'energy_monitor_panel.dart';

/// The energy monitor.
///
/// ## The leading column is empty on purpose
///
/// The reference puts Range Drop there: how much promised range each source
/// spends per kilometre actually driven. It is out of the dashboard while
/// issue 170 reworks what it measures. `RangeDropPanel` and
/// `RangeDropController` are untouched and still tested directly, in
/// `test/range_drop_panel_test.dart`; the screen simply mounts neither, so
/// nothing recomputes the stretch on the one-second tick.
///
/// To put it back: build a `RangeDropController` over the range, vehicle and
/// energy notifiers, add it to the merged animation, and swap
/// [TwoColumnLayout] for a [ThreeColumnLayout] with the panel as `leading`.
/// The two grids give `primary` and `trailing` the same widths, so nothing
/// else has to be re-proportioned either way.
///
/// TODO(v2-shell): Still on `TwoColumnLayout`. `CarplayHomeV2Screen` is on
/// `ExpandableCardStage`; this screen has no mock precedent validating a
/// staged layout for it, so it was left as-is rather than inventing one. See.
class TripsV2Screen extends StatefulWidget {
  const TripsV2Screen({
    required this.title,
    this.telemetryApi,
    this.controller,
    this.isActive = true,
    super.key,
  });

  final String title;
  final TelemetryApi? telemetryApi;

  /// Injected by tests. The screen disposes only a controller it created, so a
  /// supplied one outlives the screen.
  final EnergyMonitorController? controller;

  /// False while another destination is selected. The page stays mounted, so
  /// this is what stops the 1 s live poll behind a hidden tab.
  final bool isActive;

  @override
  State<TripsV2Screen> createState() => _TripsV2ScreenState();
}

class _TripsV2ScreenState extends State<TripsV2Screen> {
  late final EnergyMonitorController _controller =
      widget.controller ??
      EnergyMonitorController(telemetryApi: widget.telemetryApi);

  late final bool _ownsController = widget.controller == null;

  int? _selectedBar;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _controller.start();
  }

  @override
  void didUpdateWidget(covariant TripsV2Screen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive == widget.isActive) return;
    if (widget.isActive) {
      _controller.start();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    } else {
      _controller.stop();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return TwoColumnLayout(
            primary: EnergyUsePanel(
              controller: _controller,
              selectedIndex: _selectedBar,
              // Held here rather than inside the panel: the live poll rebuilds
              // that subtree every second, and a selection owned below would be
              // dropped on each tick while the reader is still reading it.
              onSelected: (index) => setState(() => _selectedBar = index),
            ),
            trailing: EnergySessionPanel(
              buckets: _controller.minutes,
              loading: _controller.isLoading,
              failed: _controller.hasFailed,
            ),
          );
        },
      ),
    );
  }
}
