import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// A value + unit + supporting line, used in the stat strip under a chart
/// (`10.8 kW` / `22 mi/hr`).
///
/// When [onIncrement] or [onDecrement] is supplied the column grows a compact
/// stepper, marking the value as directly adjustable — that is the reference's
/// signal for "this is a setting, not just a reading".
///
/// [onPressed] marks the whole column as an entry point to an editor. It steps
/// the column up onto a `control` surface and adds a pencil, because a stat
/// that opens a keypad looks exactly like the three stats beside it that do
/// nothing, and a reader must not have to find that out by tapping.
class StatColumn extends StatelessWidget {
  const StatColumn({
    required this.value,
    required this.caption,
    this.unit,
    this.onIncrement,
    this.onDecrement,
    this.onPressed,
    this.editLabel,
    super.key,
  });

  /// Pre-formatted, localized value.
  final String value;

  /// Localized supporting line.
  final String caption;

  /// Localized unit suffix, rendered small beside the value.
  final String? unit;

  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;

  /// Opens the editor this stat belongs to. Null keeps the column a reading.
  final VoidCallback? onPressed;

  /// Localized action name for the reader of a screen reader. Required with
  /// [onPressed], because the caption alone says what the number is, not what
  /// a tap does.
  final String? editLabel;

  bool get _hasStepper => onIncrement != null || onDecrement != null;

  @override
  Widget build(BuildContext context) {
    final column = _column(context);
    final onPressed = this.onPressed;
    if (onPressed == null) return column;

    final colors = AppThemeColors.of(context);
    return Semantics(
      button: true,
      label: editLabel,
      child: Material(
        color: colors.control,
        borderRadius: AppRadii.mdRadius,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadii.mdRadius,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x3,
              vertical: AppSpacing.x2,
            ),
            child: column,
          ),
        ),
      ),
    );
  }

  Widget _column(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (unit == null)
              Flexible(
                child: Text(
                  value,
                  style: AppText.statValue,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              Text(
                value,
                style: AppText.statValue,
                overflow: TextOverflow.ellipsis,
              ),
            if (unit != null) ...[
              const SizedBox(width: AppSpacing.x1),
              Flexible(
                child: Text(
                  unit!,
                  style: AppText.label,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (_hasStepper) ...[
              const SizedBox(width: AppSpacing.x2),
              _Stepper(onIncrement: onIncrement, onDecrement: onDecrement),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.x1),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                caption,
                style: AppText.caption,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onPressed != null) ...[
              const SizedBox(width: AppSpacing.x1),
              Icon(Icons.edit, size: AppSizes.iconSm, color: colors.inkSubtle),
            ],
          ],
        ),
      ],
    );
  }
}

/// Stacked chevrons beside an adjustable stat.
///
/// This is the one deliberate exception to the 64px touch minimum in
/// `DESIGN.md`: each chevron gets a 32px target so the pair still reads as a
/// stat rather than a control bar. Any adjustment that matters while driving
/// should also be reachable from a full-size control elsewhere on the card.
class _Stepper extends StatelessWidget {
  const _Stepper({this.onIncrement, this.onDecrement});

  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Chevron(icon: Icons.keyboard_arrow_up, onPressed: onIncrement),
        _Chevron(icon: Icons.keyboard_arrow_down, onPressed: onDecrement),
      ],
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron({required this.icon, this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkResponse(
        onTap: onPressed,
        radius: AppSpacing.x5,
        child: SizedBox.square(
          dimension: AppSpacing.x8,
          child: Icon(
            icon,
            size: AppSizes.iconSm,
            color: onPressed == null ? colors.inkSubtle : colors.inkMuted,
          ),
        ),
      ),
    );
  }
}
