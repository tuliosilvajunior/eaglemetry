import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';
import 'package:capy_ui/capy_ui.dart';

/// The strip of colour under the axis naming which state each stretch of the
/// "Since power on" line was in — a drive, a charge, standing time, or none
/// of the three.
///
/// One rounded block per labelled stretch, not per bucket: adjacent slots
/// sharing a label draw as one continuous block, the way the reader
/// experiences the stretch rather than the way the buckets happen to be cut.
///
/// Bar colours keep their own meaning — traction, system, climate,
/// regeneration — untouched. This is a second, independent channel below the
/// axis, on the same slot grid [TripEnergyBarChart] draws its bars on, so a
/// block always sits under the bars it names.
class EnergyStateBand extends StatelessWidget {
  const EnergyStateBand({
    required this.labels,
    required this.slotWidth,
    this.estimated,
    super.key,
  });

  /// One entry per bar slot, left to right.
  final List<ContinuousLabel> labels;

  /// One flag per entry in [labels]: true when that slot came from the
  /// sleep-gap estimate rather than a measured minute. Null when nothing in
  /// the series is estimated, which paints every block at full strength.
  final List<bool>? estimated;

  /// Unused by the geometry — every slot is the same fixed [ChartBarProfile]
  /// width regardless of how much clock it covers — but kept so a future
  /// caller does not have to change this widget's signature to reach it.
  final Duration slotWidth;

  static const double _height = 10;

  @override
  Widget build(BuildContext context) {
    final theme = AppThemeColors.of(context);
    return SizedBox(
      height: _height,
      child: CustomPaint(
        painter: _EnergyStateBandPainter(
          labels: labels,
          estimated: estimated ?? List.filled(labels.length, false),
          theme: theme,
          profile: AppSizes.chartBarProfile,
        ),
        size: Size.infinite,
      ),
    );
  }
}

/// Where a stretch's colour comes from.
///
/// Charge and drive reuse the same hues those states already carry
/// elsewhere in the app — the charge donut arc and progress fill are green,
/// the drive donut arc is amber — because a stretch really is a gain or a
/// draw in the same sense. Parked and the fourth state stay neutral: neither
/// one is an energy direction, and inventing two more hues for them would
/// compete with the six the rest of the dashboard already assigns meaning to.
Color _colorForLabel(ContinuousLabel label, AppThemeColors theme) =>
    switch (label) {
      ContinuousLabel.charge => theme.energy.gain,
      ContinuousLabel.trip => theme.energy.draw,
      ContinuousLabel.parked => theme.inkSubtle,
      ContinuousLabel.poweredOn => theme.track,
    };

class _EnergyStateBandPainter extends CustomPainter {
  _EnergyStateBandPainter({
    required this.labels,
    required this.estimated,
    required this.theme,
    required this.profile,
  });

  final List<ContinuousLabel> labels;
  final List<bool> estimated;
  final AppThemeColors theme;
  final ChartBarProfile profile;

  /// Clear space between two neighbouring blocks, mirroring the gap the bars
  /// above already keep between themselves.
  static const double _blockGap = 2;

  /// How much an estimated block is faded against its measured strength — the
  /// same "not a fresh reading" treatment [EnergyBarState.estimated] gives
  /// the bars themselves, carried down into the band that names them.
  static const double _estimatedAlpha = 0.55;

  @override
  void paint(Canvas canvas, Size size) {
    if (labels.isEmpty) return;
    final radius = Radius.circular(size.height / 2);
    var runStart = 0;
    for (var i = 1; i <= labels.length; i++) {
      if (i < labels.length &&
          labels[i] == labels[runStart] &&
          estimated[i] == estimated[runStart]) {
        continue;
      }
      final left = AppSizes.chartAxisGutter + runStart * profile.pitch;
      final right =
          AppSizes.chartAxisGutter + (i - 1) * profile.pitch + profile.width;
      final rect = Rect.fromLTRB(
        left + _blockGap / 2,
        0,
        right - _blockGap / 2,
        size.height,
      );
      if (rect.width > 0) {
        final color = _colorForLabel(labels[runStart], theme);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, radius),
          Paint()
            ..color = estimated[runStart]
                ? color.withValues(alpha: _estimatedAlpha)
                : color,
        );
      }
      runStart = i;
    }
  }

  @override
  bool shouldRepaint(covariant _EnergyStateBandPainter oldDelegate) =>
      !identical(oldDelegate.labels, labels) ||
      !identical(oldDelegate.estimated, estimated) ||
      oldDelegate.theme != theme;
}
