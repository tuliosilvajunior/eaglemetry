import 'package:flutter/material.dart';

import '../core/projection_touch_api.dart';
import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

/// The four knobs that line a forwarded touch up with the picture.
///
/// It belongs **beside** the video, never over it. Calibrating means touching
/// the projected screen and watching what reacts, so a panel that covered the
/// thing under test would make the test impossible. That is why this is built
/// for the narrow context column rather than as a dialog.
///
/// Each nudge writes straight through to the native side and is saved there, so
/// the next touch already uses it. There is no apply step: an apply button
/// turns a two-second loop — nudge, touch, look — into a four-step one.
class ProjectionTouchCalibrationPanel extends StatelessWidget {
  const ProjectionTouchCalibrationPanel({
    required this.calibration,
    required this.step,
    required this.onStepChanged,
    required this.onChanged,
    this.resetTarget = ProjectionTouchCalibration.identity,
    super.key,
  });

  final ProjectionTouchCalibration calibration;

  /// What reset goes back to, which is the measured default for this stack and
  /// not always the identity. On Android Auto the identity is the state that is
  /// known to be wrong, so a reset to it would undo a correction the car needs.
  final ProjectionTouchCalibration resetTarget;

  /// How much one nudge moves. Coarse finds the neighbourhood, fine lands on
  /// the key — the two together are what make this converge by hand.
  final ProjectionTouchCalibrationStep step;

  final ValueChanged<ProjectionTouchCalibrationStep> onStepChanged;
  final ValueChanged<ProjectionTouchCalibration> onChanged;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final offsetStep = step.offsetPixels;
    final scaleStep = step.scaleFraction;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TrackSegmentedControl<ProjectionTouchCalibrationStep>(
          items: [
            TabItem(
              value: ProjectionTouchCalibrationStep.fine,
              label: loc.v2ProjectionTouchStepFine,
            ),
            TabItem(
              value: ProjectionTouchCalibrationStep.coarse,
              label: loc.v2ProjectionTouchStepCoarse,
            ),
          ],
          selected: step,
          onSelected: onStepChanged,
        ),
        const SizedBox(height: AppSpacing.x3),
        // Vertical first, and not for symmetry: on this head unit the vertical
        // mismatch is the one that moves a touch a whole keyboard row, while
        // the horizontal one stays inside a key. The knob that matters is the
        // one the reader should reach first.
        _Row(
          label: loc.v2ProjectionTouchOffsetY,
          value: _pixels(calibration.offsetY),
          onLess: () => onChanged(
            calibration.copyWith(offsetY: calibration.offsetY - offsetStep),
          ),
          onMore: () => onChanged(
            calibration.copyWith(offsetY: calibration.offsetY + offsetStep),
          ),
        ),
        _Row(
          label: loc.v2ProjectionTouchScaleY,
          value: _percent(calibration.scaleY),
          onLess: () => onChanged(
            calibration.copyWith(scaleY: calibration.scaleY - scaleStep),
          ),
          onMore: () => onChanged(
            calibration.copyWith(scaleY: calibration.scaleY + scaleStep),
          ),
        ),
        _Row(
          label: loc.v2ProjectionTouchOffsetX,
          value: _pixels(calibration.offsetX),
          onLess: () => onChanged(
            calibration.copyWith(offsetX: calibration.offsetX - offsetStep),
          ),
          onMore: () => onChanged(
            calibration.copyWith(offsetX: calibration.offsetX + offsetStep),
          ),
        ),
        _Row(
          label: loc.v2ProjectionTouchScaleX,
          value: _percent(calibration.scaleX),
          onLess: () => onChanged(
            calibration.copyWith(scaleX: calibration.scaleX - scaleStep),
          ),
          onMore: () => onChanged(
            calibration.copyWith(scaleX: calibration.scaleX + scaleStep),
          ),
        ),
        const SizedBox(height: AppSpacing.x2),
        SoftActionTile(
          icon: Icons.restart_alt,
          label: loc.v2ProjectionTouchReset,
          // Disabled at the default so the control says whether anything has
          // been tuned at all, which is otherwise four numbers to read.
          onPressed: calibration == resetTarget
              ? null
              : () => onChanged(resetTarget),
          height: AppSizes.actionRowHeight,
        ),
      ],
    );
  }

  /// Signed on purpose: which way it moved is the whole reading, and a bare
  /// `12 px` cannot be told from `−12 px` when the reader is mid-loop.
  static String _pixels(double value) {
    final rounded = value.round();
    return '${rounded > 0 ? '+' : ''}$rounded px';
  }

  static String _percent(double value) =>
      '${(value * 100).toStringAsFixed(1)} %';
}

/// How far one nudge moves.
enum ProjectionTouchCalibrationStep {
  fine(offsetPixels: 4, scaleFraction: 0.005),
  coarse(offsetPixels: 24, scaleFraction: 0.025);

  const ProjectionTouchCalibrationStep({
    required this.offsetPixels,
    required this.scaleFraction,
  });

  /// Buffer pixels, not logical ones — the correction lives in buffer space, so
  /// it is worth the same however large the card is drawn.
  final double offsetPixels;
  final double scaleFraction;
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    required this.onLess,
    required this.onMore,
  });

  final String label;
  final String value;
  final VoidCallback onLess;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: AppText.caption, maxLines: 1),
                Text(value, style: AppText.metricSm, maxLines: 1),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.x2),
          SquareIconButton(
            icon: Icons.remove,
            onPressed: onLess,
            tooltip: label,
            size: AppSizes.minTouchTarget,
          ),
          const SizedBox(width: AppSpacing.x2),
          SquareIconButton(
            icon: Icons.add,
            onPressed: onMore,
            tooltip: label,
            size: AppSizes.minTouchTarget,
          ),
        ],
      ),
    );
  }
}
