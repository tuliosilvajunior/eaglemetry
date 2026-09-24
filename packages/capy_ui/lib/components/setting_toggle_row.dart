import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// A named setting with a switch on the right, on the same grey control fill
/// as [SoftActionTile].
///
/// The on state is the theme's amber ([AppThemeColors.of(context).energy.draw]), matching the
/// reference head unit. This is a deliberate, named exception to rule 3 in
/// `DESIGN.md` — the one place a series hue carries a control state — and it
/// holds only for a switch: an amber track reads as *live* at a glance across
/// a cabin, which is the whole job of a settings switch. Do not spread it to
/// tabs, tiles, or any other selection; those stay on `selectionFill`.
///
/// The whole row is the target, not just the switch: a 52px switch is not a
/// thing to hit while driving. [onChanged] null renders the row disabled, with
/// the label dropping to `inkSubtle` and the switch left in place showing the
/// state it is stuck in, rather than the row disappearing.
class SettingToggleRow extends StatelessWidget {
  const SettingToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.description,
    super.key,
  });

  /// Localized label.
  final String label;

  /// Localized supporting line under the label. Omit for a bare row.
  final String? description;

  final bool value;

  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final enabled = onChanged != null;
    final description = this.description;

    return Material(
      color: colors.control,
      borderRadius: AppRadii.mdRadius,
      child: InkWell(
        onTap: enabled ? () => onChanged!(!value) : null,
        borderRadius: AppRadii.mdRadius,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x4,
              vertical: AppSpacing.x3,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: AppText.body.copyWith(
                          color: enabled ? colors.ink : colors.inkSubtle,
                        ),
                      ),
                      if (description != null) ...[
                        const SizedBox(height: AppSpacing.x1),
                        Text(
                          description,
                          style: AppText.label.copyWith(
                            color: enabled ? colors.inkMuted : colors.inkSubtle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.x4),
                // Excluded from semantics because the row above already
                // exposes the toggle: leaving both in announces the same
                // setting twice and offers two targets for one action.
                ExcludeSemantics(
                  child: Switch(
                    value: value,
                    onChanged: onChanged,
                    activeThumbColor: colors.surface,
                    activeTrackColor: AppThemeColors.of(context).energy.draw,
                    inactiveThumbColor: colors.surface,
                    inactiveTrackColor: colors.track,
                    trackOutlineColor: WidgetStateProperty.all(
                      AppColors.transparent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
