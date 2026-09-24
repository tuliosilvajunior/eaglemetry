import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// What a session did to the battery, drawn as the stretch between two charges.
///
/// The scale is always the whole battery, zero to 100 %, so two sessions can be
/// compared by looking at them. What the bar carries is the *span*: where the
/// battery started and where it ended, with the stretch between them marked.
///
/// It is a sibling of `CycleBar` and of `LimitSlider`, not a use of either.
/// `CycleBar` fills from zero, because a cycle counts what a whole battery was
/// spent on. `LimitSlider` has a knob and a selectable range, because a charge
/// target is a setting. A recorded session is neither: nothing here can be
/// changed, and the interesting part does not start at zero.
///
/// The direction of the span is the reading. A drive ends lower than it began
/// and the stretch is drawn in the loss colour; a charge ends higher and it is
/// drawn in the gain colour. Nothing else in the component decides which — the
/// two ends do, so a drive that somehow ended higher would say so rather than
/// be repainted into the expected story.
///
/// It draws no animation. These repeat down a list, and a list that breathes is
/// a distraction.
class SocSpanBar extends StatelessWidget {
  const SocSpanBar({
    required this.startPercent,
    required this.endPercent,
    required this.startLabel,
    required this.endLabel,
    this.semanticsLabel,
    super.key,
  });

  /// State of charge at the two ends, 0 to 100. Values outside that are
  /// clamped: the pill is the whole battery and cannot overflow.
  final double startPercent;
  final double endPercent;

  /// The pre-formatted numerals for the two ends. Both come from the caller,
  /// because nothing here may build a visible string.
  final String startLabel;
  final String endLabel;

  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final start = _clamp(startPercent);
    final end = _clamp(endPercent);
    final low = start < end ? start : end;
    final high = start < end ? end : start;
    // A charge gains, a drive loses. The colour follows the measurement.
    final spanColor = end >= start
        ? colors.energy.gain
        : colors.energy.critical;

    return Semantics(
      label: semanticsLabel,
      readOnly: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: AppSizes.socSpanBarHeight,
            child: ClipRRect(
              borderRadius: AppRadii.fullRadius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: colors.track),
                  // The battery that was never in play is held rather than
                  // spent, so it takes the neutral control surface and not the
                  // colour of the span.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: low / 100,
                      heightFactor: 1,
                      child: ColoredBox(color: colors.control),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: high / 100,
                      heightFactor: 1,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: FractionallySizedBox(
                          // Guarded, because a session that moved the battery
                          // by nothing would divide by a zero span.
                          widthFactor: high <= 0
                              ? 0
                              : ((high - low) / high).clamp(0.0, 1.0),
                          heightFactor: 1,
                          child: ColoredBox(color: spanColor),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                startLabel,
                style: AppText.label.copyWith(color: colors.inkMuted),
              ),
              Text(
                endLabel,
                style: AppText.bodyStrong.copyWith(color: colors.ink),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static double _clamp(double value) =>
      value.isFinite ? value.clamp(0.0, 100.0).toDouble() : 0.0;
}
