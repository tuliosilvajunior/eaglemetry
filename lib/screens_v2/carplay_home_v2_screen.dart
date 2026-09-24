import 'package:flutter/material.dart';

import '../core/carplay_api.dart';
import '../core/energy_monitor_controller.dart';
import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import 'carplay_v2_screen.dart';
import 'energy_session_panel.dart';

/// The CarPlay destination: the live video surface, plus room beside it.
///
/// The surface is an [ExpandableCardStage] slot rather than a column of a
/// `Row`, because it is the one card in the v2 shell that can be dragged to
/// fill the screen. It used to ride that stage from inside the "Now"
/// destination; the surface now lives on CarPlay's own tab, which is where a
/// user looks for it, and Now is gone.
class CarplayHomeV2Screen extends StatefulWidget {
  const CarplayHomeV2Screen({
    required this.title,
    required this.isActive,
    required this.stage,
    this.carplayApi,
    this.energyController,
    super.key,
  });

  final String title;

  /// True while this is the selected destination. Forwarded to
  /// [CarplayV2Screen], which may hold the OEM renderer only while it is (R1).
  final bool isActive;

  /// Owned by the shell, not here: expanding the surface has to hide chrome
  /// (the pill row) that lives outside this screen's own subtree, and that
  /// chrome has to move on the same clock as the card. See
  /// `CardStageController`'s own doc comment for why ownership sits above
  /// whichever widget hosts the stage.
  final CardStageController stage;

  final CarplayApi? carplayApi;

  /// Injected by tests. The screen disposes only a controller it created, so a
  /// supplied one outlives the screen.
  final EnergyMonitorController? energyController;

  @override
  State<CarplayHomeV2Screen> createState() => _CarplayHomeV2ScreenState();
}

class _CarplayHomeV2ScreenState extends State<CarplayHomeV2Screen> {
  /// Resolved once and handed down to [CarplayV2Screen], rather than letting
  /// that screen default to an instance of its own: the reattach action below
  /// and the surface it is meant to fix have to be talking to the same host
  /// connection, the same reason `AppShellV2` shares one instance with both.
  late final CarplayApi _api = widget.carplayApi ?? CarplayApi();

  /// The drive the ring beside the surface reports. Its own controller: the
  /// two projection tabs are never on screen together. [isActive] stops the
  /// poll when this destination is hidden, so a keep-alive page does not
  /// keep reading behind another tab.
  late final EnergyMonitorController _energy =
      widget.energyController ?? EnergyMonitorController();

  late final bool _ownsEnergy = widget.energyController == null;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _energy.start();
  }

  @override
  void didUpdateWidget(covariant CarplayHomeV2Screen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive == widget.isActive) return;
    if (widget.isActive) {
      _energy.start();
    } else {
      _energy.stop();
    }
  }

  @override
  void dispose() {
    if (_ownsEnergy) {
      _energy.dispose();
    } else {
      _energy.stop();
    }
    super.dispose();
  }

  /// Resting units for [surface, context] — 3/1 out of 4 total, the same 3/4
  /// split `TwoColumnLayout` gave this tab before it moved onto the stage.
  /// Fixed rather than a [CardStageResize]: neither card has a resize
  /// affordance today.
  static const _units = [3.0, 1.0];
  static const _surfaceIndex = 0;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return SizedBox.expand(
      child: ExpandableCardStage(
        stage: widget.stage,
        expandableIndex: _surfaceIndex,
        expandSemanticsLabel: loc.v2CarplayExpand,
        collapseSemanticsLabel: loc.v2CarplayCollapse,
        // The surface forwards every touch on it to the phone, and the phone
        // scrolls its lists and pans its maps with the same drags this stage
        // used to claim. The two mean different things over the same pixels
        // and no arbitration can tell them apart, so the expand drag moves to
        // a grip and the rest of the card belongs to CarPlay.
        dragSource: CardStageDragSource.handle,
        slots: [
          // `stable`, and load-bearing: a size-aware slot is re-keyed whenever
          // its `CardSize` changes, which disposes the outgoing subtree. The
          // surface owns the OEM renderer through a channel, so that dispose
          // is a `deactivate()` — detach, texture released, service unbound —
          // landing right as the expand gesture completes, and the survivor
          // already believes it is active so nothing asks for the video back.
          // The card looks identical at every size anyway; there was never
          // anything to cross-fade.
          CardStageSlot.stable(
            units: _units[0],
            // Stacked, not stacked *into* a column: the grip floats over the
            // video and takes no height from it. A bar would crop the picture
            // by its own height at every size.
            child: Stack(
              children: [
                Positioned.fill(
                  child: CarplayV2Screen(
                    key: const ValueKey('carplay-surface'),
                    title: widget.title,
                    isActive: widget.isActive,
                    carplayApi: _api,
                    surfaceOnly: true,
                  ),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: CardStageDragHandle(
                    stage: widget.stage,
                    semanticsLabel: loc.v2CarplayDragHandle,
                  ),
                ),
              ],
            ),
          ),
          CardStageSlot(
            units: _units[1],
            builder: (_) => AppCard(
              title: loc.sessionDetailsTitle,
              // The column beside a phone screen is the one place in the shell
              // with room and nothing to say. The ring is what the driver would
              // otherwise change tabs to read, and it costs the surface
              // nothing.
              child: AnimatedBuilder(
                animation: _energy,
                builder: (context, _) => EnergySessionRing(
                  buckets: _energy.minutes,
                  loading: _energy.isLoading,
                  failed: _energy.hasFailed,
                  showInfoButton: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
