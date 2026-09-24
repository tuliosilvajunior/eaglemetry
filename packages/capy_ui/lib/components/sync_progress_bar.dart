import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// Progress bar indicating cloud synchronization progress (clean vs dirty records).
///
/// Designed per `packages/capy_ui/DESIGN.md`:
/// - Generous `AppRadii.fullRadius` bar.
/// - Unfilled track uses `colors.control`.
/// - Filled section uses `colors.energy.gain` when fully in sync (`dirty == 0`),
///   or `colors.energy.draw` (amber) when items are pending upload.
/// - Clean typography showing status and optional detail line.
/// - The fill moves to a new reading over `AppMotion.slow`, and jumps straight
///   to it when the platform asks for reduced motion.
class SyncProgressBar extends StatelessWidget {
  const SyncProgressBar({
    required this.progress,
    this.label,
    this.statusText,
    this.detailText,
    this.height = 8.0,
    super.key,
  });

  /// Cloud vs local counts.
  final SyncProgressData progress;

  /// Optional header label (e.g. 'Status na nuvem').
  final String? label;

  /// Status description placed to the right of [label]
  /// (e.g. '100% em dia' or '85% (12 pendentes)').
  /// If null, defaults to `'$percentage%'`.
  final String? statusText;

  /// Optional caption below the bar with further details.
  final String? detailText;

  /// Height of the progress bar track. Defaults to 8.0.
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final isUpToDate = progress.isUpToDate;
    final ratio = progress.ratio;
    final percentage = progress.percentage;

    final fillColor = isUpToDate ? colors.energy.gain : colors.energy.draw;
    final rightStatus = statusText ?? '$percentage%';
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null || statusText != null) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (label != null)
                Expanded(
                  child: Text(
                    label!,
                    style: AppText.label.copyWith(color: colors.inkMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              else
                const Spacer(),
              const SizedBox(width: AppSpacing.x2),
              Text(
                rightStatus,
                style: AppText.label.copyWith(
                  color: isUpToDate ? colors.energy.gain : colors.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x2),
        ],
        Container(
          height: height,
          decoration: BoxDecoration(
            color: colors.control,
            borderRadius: AppRadii.fullRadius,
          ),
          clipBehavior: Clip.antiAlias,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final fillWidth = (constraints.maxWidth * ratio).clamp(
                0.0,
                constraints.maxWidth,
              );
              return Align(
                alignment: Alignment.centerLeft,
                child: AnimatedContainer(
                  duration: reduceMotion ? Duration.zero : AppMotion.slow,
                  curve: AppMotion.curve,
                  width: fillWidth,
                  decoration: BoxDecoration(
                    color: fillColor,
                    borderRadius: AppRadii.fullRadius,
                  ),
                ),
              );
            },
          ),
        ),
        if (detailText != null) ...[
          const SizedBox(height: AppSpacing.x1),
          Text(
            detailText!,
            style: AppText.caption.copyWith(color: colors.inkSubtle),
          ),
        ],
      ],
    );
  }
}
