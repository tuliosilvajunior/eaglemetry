import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'anchored_tooltip.dart';
import 'metric_value.dart';

/// Opens the charging-amperage panel through the shared anchored-tooltip
/// behavior. Use [AnchoredTooltipTrigger] when the source must also show its
/// selected state while the panel is open.
Future<void> showChargingAmperageDialog({
  required BuildContext context,
  required BuildContext anchorContext,
  required int value,
  required ValueChanged<int> onChanged,
  required String title,
  required String description,
  required String defaultLabel,
  required String unit,
  required String decreaseLabel,
  required String increaseLabel,
  required String barrierLabel,
  AnchoredTooltipSide anchorSide = AnchoredTooltipSide.right,
  int min = 1,
  int max = 48,
  int step = 1,
}) {
  return showAnchoredTooltip(
    context: context,
    anchorContext: anchorContext,
    side: anchorSide,
    caretAlignment: 0.85,
    barrierLabel: barrierLabel,
    tooltipBuilder: (context) => ChargingAmperageDialog(
      value: value,
      onChanged: onChanged,
      title: title,
      description: description,
      defaultLabel: defaultLabel,
      unit: unit,
      decreaseLabel: decreaseLabel,
      increaseLabel: increaseLabel,
      min: min,
      max: max,
      step: step,
    ),
  );
}

/// Floating editor content for charging amperage.
///
/// The caller owns the actual vehicle setting. This widget owns only the value
/// while its tooltip route is visible.
class ChargingAmperageDialog extends StatefulWidget {
  const ChargingAmperageDialog({
    required this.value,
    required this.onChanged,
    required this.title,
    required this.description,
    required this.defaultLabel,
    required this.unit,
    required this.decreaseLabel,
    required this.increaseLabel,
    this.min = 1,
    this.max = 48,
    this.step = 1,
    super.key,
  }) : assert(min <= max),
       assert(step > 0),
       assert(value >= min && value <= max);

  final int value;
  final ValueChanged<int> onChanged;
  final String title;
  final String description;
  final String defaultLabel;
  final String unit;
  final String decreaseLabel;
  final String increaseLabel;
  final int min;
  final int max;
  final int step;

  @override
  State<ChargingAmperageDialog> createState() => _ChargingAmperageDialogState();
}

class _ChargingAmperageDialogState extends State<ChargingAmperageDialog> {
  late int _value = widget.value;

  void _changeBy(int delta) {
    final next = (_value + delta).clamp(widget.min, widget.max);
    if (next == _value) return;

    setState(() => _value = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return AnchoredTooltipSurface(
      height: AppSizes.amperageDialogHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.x6,
          AppSpacing.x6,
          AppSpacing.x6,
          AppSpacing.x5,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: AppText.cardTitle),
            const SizedBox(height: AppSpacing.x3),
            Text(
              widget.description,
              style: AppText.body.copyWith(color: colors.inkMuted),
            ),
            const SizedBox(height: AppSpacing.x4),
            Text(
              widget.defaultLabel,
              style: AppText.label.copyWith(color: colors.inkSubtle),
            ),
            const Spacer(),
            MetricValue(
              value: '$_value',
              unit: widget.unit,
              size: MetricSize.xl,
              valueColor: colors.inkMuted,
              unitColor: colors.inkSubtle,
            ),
            const SizedBox(height: AppSpacing.x5),
            Row(
              children: [
                Expanded(
                  child: _StepButton(
                    key: const Key('charging-amperage-decrease'),
                    icon: Icons.keyboard_arrow_down,
                    label: widget.decreaseLabel,
                    onPressed: _value > widget.min
                        ? () => _changeBy(-widget.step)
                        : null,
                  ),
                ),
                const SizedBox(width: AppSpacing.x1),
                Expanded(
                  child: _StepButton(
                    key: const Key('charging-amperage-increase'),
                    icon: Icons.keyboard_arrow_up,
                    label: widget.increaseLabel,
                    onPressed: _value < widget.max
                        ? () => _changeBy(widget.step)
                        : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final enabled = onPressed != null;

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: colors.control,
          borderRadius: AppRadii.smRadius,
          child: InkWell(
            onTap: onPressed,
            borderRadius: AppRadii.smRadius,
            child: SizedBox(
              height: AppSizes.amperageDialogStepHeight,
              child: Icon(
                icon,
                size: AppSizes.iconLg,
                color: enabled ? colors.inkMuted : colors.inkSubtle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
