import 'package:flutter/material.dart';

import '../core/android_auto_api.dart';
import '../core/energy_monitor_controller.dart';
import '../core/projection_touch_api.dart';
import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import 'android_auto_v2_screen.dart';
import 'energy_session_panel.dart';

/// The Android Auto destination: the live video surface, plus room beside it.
///
/// The surface is an [ExpandableCardStage] slot rather than a column of a
/// `Row`, because it is the one card in the v2 shell that can be dragged to
/// fill the screen. It used to ride that stage from inside the "Now"
/// destination; the surface now lives on Android Auto's own tab, which is where a
/// user looks for it, and Now is gone.
class AndroidAutoHomeV2Screen extends StatefulWidget {
  const AndroidAutoHomeV2Screen({
    required this.title,
    required this.isActive,
    required this.stage,
    this.androidAutoApi,
    this.touchApi,
    this.energyController,
    super.key,
  });

  final String title;

  /// True while this is the selected destination. Forwarded to
  /// [AndroidAutoV2Screen], which may hold the OEM renderer only while it is (R1).
  final bool isActive;

  /// Owned by the shell, not here: expanding the surface has to hide chrome
  /// (the pill row) that lives outside this screen's own subtree, and that
  /// chrome has to move on the same clock as the card. See
  /// `CardStageController`'s own doc comment for why ownership sits above
  /// whichever widget hosts the stage.
  final CardStageController stage;

  final AndroidAutoApi? androidAutoApi;

  /// Shared with the surface, for the same reason [androidAutoApi] is: the
  /// calibration panel here and the touches it corrects must be talking to one
  /// connection, or the panel would tune a path nobody is using.
  final ProjectionTouchApi? touchApi;

  /// Injected by tests. The screen disposes only a controller it created, so a
  /// supplied one outlives the screen.
  final EnergyMonitorController? energyController;

  @override
  State<AndroidAutoHomeV2Screen> createState() =>
      _AndroidAutoHomeV2ScreenState();
}

class _AndroidAutoHomeV2ScreenState extends State<AndroidAutoHomeV2Screen> {
  /// Resolved once and handed down to [AndroidAutoV2Screen], rather than letting
  /// that screen default to an instance of its own: the reattach action below
  /// and the surface it is meant to fix have to be talking to the same host
  /// connection, the same reason `AppShellV2` shares one instance with both.
  late final AndroidAutoApi _api = widget.androidAutoApi ?? AndroidAutoApi();

  /// Resolved here and handed to the surface, so a caller that supplies one
  /// reaches the touches this screen forwards.
  late final ProjectionTouchApi _touch =
      widget.touchApi ?? ProjectionTouchApi();

  /// The drive the ring above the calibration reports. Its own controller, for
  /// the same reason the CarPlay tab keeps one. [isActive] stops the poll
  /// when this destination is hidden.
  late final EnergyMonitorController _energy =
      widget.energyController ?? EnergyMonitorController();

  late final bool _ownsEnergy = widget.energyController == null;

  /// Resting units for [surface, context] — 3/1 out of 4 total, the same 3/4
  /// split `TwoColumnLayout` gave this tab before it moved onto the stage.
  /// Fixed rather than a [CardStageResize]: neither card has a resize
  /// affordance today.
  static const _units = [3.0, 1.0];
  static const _surfaceIndex = 0;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _energy.start();
  }

  @override
  void didUpdateWidget(covariant AndroidAutoHomeV2Screen oldWidget) {
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

  /// Writes the nudge through at once and shows what came back.
  ///
  /// Optimistic in between: the reader is mid-loop with a finger already on
  /// the projected screen, and a value that only appears after the channel
  /// answers reads as a control that missed the press.
  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return SizedBox.expand(
      child: ExpandableCardStage(
        stage: widget.stage,
        expandableIndex: _surfaceIndex,
        expandSemanticsLabel: loc.v2AndroidAutoExpand,
        collapseSemanticsLabel: loc.v2AndroidAutoCollapse,
        // Same reason as the CarPlay twin of this screen: the surface forwards
        // every drag on it to the phone, where the same gesture scrolls a list
        // or pans a map, so the expand drag moves to a grip.
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
            // video and takes no height from it.
            child: Stack(
              children: [
                Positioned.fill(
                  child: AndroidAutoV2Screen(
                    key: const ValueKey('android-auto-surface'),
                    title: widget.title,
                    isActive: widget.isActive,
                    androidAutoApi: _api,
                    touchApi: _touch,
                    surfaceOnly: true,
                  ),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: CardStageDragHandle(
                    stage: widget.stage,
                    semanticsLabel: loc.v2AndroidAutoDragHandle,
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
