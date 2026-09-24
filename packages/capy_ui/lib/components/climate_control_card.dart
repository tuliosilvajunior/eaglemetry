import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'app_card.dart';
import 'climate_temperature_bar.dart';
import 'icon_buttons.dart';
import 'metric_value.dart';
import 'soft_action_tile.dart';

/// Climate control card: the vehicle temperature, fan and HVAC quick actions
/// in one panel.
///
/// Every value is controlled by the caller, the same shape as
/// [SoftActionTile] and [SettingToggleRow]: this widget draws no telemetry and
/// writes nothing to the vehicle by itself. A stepper callback left null
/// disables that button rather than hiding it — that is how the caller states
/// a real vehicle limit (the car will not go colder/hotter, will not step the
/// fan further) without this component ever inventing a bound of its own, per
/// the "never invent the bounds of a vehicle control" rule in `AGENTS.md`. A
/// toggle callback left null renders that action disabled for the same
/// reason — a feature the connected car does not report is not offered.
///
/// [temperatureValue] and [fanSpeedLevel]'s caption are pre-formatted,
/// localized strings — formatting stays with the caller, the same convention
/// [MetricValue] and [StatColumn] use.
class ClimateControlCard extends StatelessWidget {
  const ClimateControlCard({
    required this.title,
    required this.temperatureValue,
    required this.temperatureUnit,
    required this.decreaseTemperatureLabel,
    required this.increaseTemperatureLabel,
    required this.autoLabel,
    required this.autoEnabled,
    required this.fanSpeedLevel,
    required this.fanSpeedMaxLevel,
    required this.decreaseFanSpeedLabel,
    required this.increaseFanSpeedLabel,
    required this.acLabel,
    required this.acEnabled,
    required this.syncLabel,
    required this.syncEnabled,
    required this.defrostLabel,
    required this.defrostEnabled,
    required this.seatHeatLabel,
    required this.seatHeatEnabled,
    required this.steeringWheelHeatLabel,
    required this.steeringWheelHeatEnabled,
    required this.petModeLabel,
    required this.petModeEnabled,
    required this.climateScheduleLabel,
    this.subtitle,
    this.onDecreaseTemperature,
    this.onIncreaseTemperature,
    this.onAutoChanged,
    this.fanSpeedCaption,
    this.onDecreaseFanSpeed,
    this.onIncreaseFanSpeed,
    this.onAcChanged,
    this.onSyncChanged,
    this.onDefrostChanged,
    this.onSeatHeatChanged,
    this.onSteeringWheelHeatChanged,
    this.onPetModeChanged,
    this.onClimateSchedulePressed,
    super.key,
  });

  /// Localized card title.
  final String title;

  /// Localized supporting line under the title.
  final String? subtitle;

  // --- Temperature -----------------------------------------------------

  /// Pre-formatted numeral (`21.5`).
  final String temperatureValue;

  /// Localized unit suffix (`°C`).
  final String temperatureUnit;

  final String decreaseTemperatureLabel;
  final String increaseTemperatureLabel;

  /// Null disables the button — the car reported it is already at its floor.
  final VoidCallback? onDecreaseTemperature;

  /// Null disables the button — the car reported it is already at its ceiling.
  final VoidCallback? onIncreaseTemperature;

  // --- Auto ---------------------------------------------------------------

  final String autoLabel;
  final bool autoEnabled;

  /// Null renders the toggle disabled — the car does not report an AUTO mode.
  final ValueChanged<bool>? onAutoChanged;

  // --- Fan speed ------------------------------------------------------------

  /// Current fan step, `0` to [fanSpeedMaxLevel].
  final int fanSpeedLevel;

  /// The span the car declares for the fan-speed dots. Never a constant here —
  /// the caller reads it from the vehicle.
  final int fanSpeedMaxLevel;

  final String decreaseFanSpeedLabel;
  final String increaseFanSpeedLabel;
  final VoidCallback? onDecreaseFanSpeed;
  final VoidCallback? onIncreaseFanSpeed;

  /// Optional localized caption under the fan dots (`Low`).
  final String? fanSpeedCaption;

  // --- Mode row: AC, sync, front defrost ------------------------------------

  final String acLabel;
  final bool acEnabled;
  final ValueChanged<bool>? onAcChanged;

  final String syncLabel;
  final bool syncEnabled;
  final ValueChanged<bool>? onSyncChanged;

  final String defrostLabel;
  final bool defrostEnabled;
  final ValueChanged<bool>? onDefrostChanged;

  // --- Quick toggles: seat heat, steering wheel heat, pet mode --------------

  final String seatHeatLabel;
  final bool seatHeatEnabled;
  final ValueChanged<bool>? onSeatHeatChanged;

  final String steeringWheelHeatLabel;
  final bool steeringWheelHeatEnabled;
  final ValueChanged<bool>? onSteeringWheelHeatChanged;

  final String petModeLabel;
  final bool petModeEnabled;
  final ValueChanged<bool>? onPetModeChanged;

  // --- Climate schedule entry -------------------------------------------

  final String climateScheduleLabel;
  final VoidCallback? onClimateSchedulePressed;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      title: title,
      subtitle: subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _TemperatureStepper(
            value: temperatureValue,
            unit: temperatureUnit,
            decreaseLabel: decreaseTemperatureLabel,
            increaseLabel: increaseTemperatureLabel,
            onDecrease: onDecreaseTemperature,
            onIncrease: onIncreaseTemperature,
          ),
          const SizedBox(height: AppSpacing.x6),
          SoftActionTile(
            label: autoLabel,
            icon: Icons.auto_mode,
            centered: true,
            selected: autoEnabled,
            onPressed: onAutoChanged == null
                ? null
                : () => onAutoChanged!(!autoEnabled),
          ),
          const SizedBox(height: AppSpacing.x4),
          _FanSpeedControl(
            level: fanSpeedLevel,
            maxLevel: fanSpeedMaxLevel,
            caption: fanSpeedCaption,
            decreaseLabel: decreaseFanSpeedLabel,
            increaseLabel: increaseFanSpeedLabel,
            onDecrease: onDecreaseFanSpeed,
            onIncrease: onIncreaseFanSpeed,
          ),
          const SizedBox(height: AppSpacing.x6),
          Row(
            children: [
              Expanded(
                child: SoftActionTile(
                  label: acLabel,
                  icon: Icons.ac_unit,
                  centered: true,
                  selected: acEnabled,
                  onPressed: onAcChanged == null
                      ? null
                      : () => onAcChanged!(!acEnabled),
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: SoftActionTile(
                  label: syncLabel,
                  icon: Icons.sync,
                  centered: true,
                  selected: syncEnabled,
                  onPressed: onSyncChanged == null
                      ? null
                      : () => onSyncChanged!(!syncEnabled),
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: SoftActionTile(
                  label: defrostLabel,
                  icon: Icons.window,
                  centered: true,
                  selected: defrostEnabled,
                  onPressed: onDefrostChanged == null
                      ? null
                      : () => onDefrostChanged!(!defrostEnabled),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x4),
          Row(
            children: [
              Expanded(
                child: SoftActionTile(
                  label: seatHeatLabel,
                  icon: Icons.event_seat,
                  centered: true,
                  selected: seatHeatEnabled,
                  onPressed: onSeatHeatChanged == null
                      ? null
                      : () => onSeatHeatChanged!(!seatHeatEnabled),
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: SoftActionTile(
                  label: steeringWheelHeatLabel,
                  leading: const SteeringWheelIcon(),
                  centered: true,
                  selected: steeringWheelHeatEnabled,
                  onPressed: onSteeringWheelHeatChanged == null
                      ? null
                      : () => onSteeringWheelHeatChanged!(
                          !steeringWheelHeatEnabled,
                        ),
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              Expanded(
                child: SoftActionTile(
                  label: petModeLabel,
                  icon: Icons.pets,
                  centered: true,
                  selected: petModeEnabled,
                  onPressed: onPetModeChanged == null
                      ? null
                      : () => onPetModeChanged!(!petModeEnabled),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.x4),
          _ScheduleRow(
            label: climateScheduleLabel,
            onPressed: onClimateSchedulePressed,
          ),
        ],
      ),
    );
  }
}

/// Hero row: the large temperature readout flanked by two full-size steppers.
/// The whole reason this card exists, so it gets the automotive-minimum
/// controls rather than the compact chevrons `StatColumn` uses for a reading
/// that is adjustable but secondary.
class _TemperatureStepper extends StatelessWidget {
  const _TemperatureStepper({
    required this.value,
    required this.unit,
    required this.decreaseLabel,
    required this.increaseLabel,
    this.onDecrease,
    this.onIncrease,
  });

  final String value;
  final String unit;
  final String decreaseLabel;
  final String increaseLabel;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SquareIconButton(
          icon: Icons.remove,
          onPressed: onDecrease,
          tooltip: decreaseLabel,
          size: AppSizes.minTouchTarget,
        ),
        Expanded(
          child: Center(
            child: MetricValue(value: value, unit: unit, size: MetricSize.xl),
          ),
        ),
        SquareIconButton(
          icon: Icons.add,
          onPressed: onIncrease,
          tooltip: increaseLabel,
          size: AppSizes.minTouchTarget,
        ),
      ],
    );
  }
}

/// Fan icon over a step-dot row, flanked by the same full-size steppers as the
/// temperature. The dot count is [_FanSpeedControl.maxLevel], read from the
/// car rather than fixed, so the row never offers a step the vehicle refuses.
class _FanSpeedControl extends StatelessWidget {
  const _FanSpeedControl({
    required this.level,
    required this.maxLevel,
    required this.decreaseLabel,
    required this.increaseLabel,
    this.caption,
    this.onDecrease,
    this.onIncrease,
  });

  final int level;
  final int maxLevel;
  final String? caption;
  final String decreaseLabel;
  final String increaseLabel;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Row(
      children: [
        SquareIconButton(
          icon: Icons.remove,
          onPressed: onDecrease,
          tooltip: decreaseLabel,
          size: AppSizes.minTouchTarget,
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FanIcon(
                size: AppSizes.iconLg,
                color: colors.ink,
                filled: level > 0,
              ),
              const SizedBox(height: AppSpacing.x2),
              _FanSpeedDots(
                key: const Key('climate-fan-dots'),
                level: level,
                maxLevel: maxLevel,
              ),
              if (caption != null) ...[
                const SizedBox(height: AppSpacing.x1),
                Text(
                  caption!,
                  style: AppText.label.copyWith(color: colors.inkMuted),
                ),
              ],
            ],
          ),
        ),
        SquareIconButton(
          icon: Icons.add,
          onPressed: onIncrease,
          tooltip: increaseLabel,
          size: AppSizes.minTouchTarget,
        ),
      ],
    );
  }
}

class _FanSpeedDots extends StatelessWidget {
  const _FanSpeedDots({required this.level, required this.maxLevel, super.key});

  final int level;
  final int maxLevel;

  static const _dotSize = 8.0;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    if (maxLevel <= 0) return const SizedBox.shrink();
    final filled = level.clamp(0, maxLevel);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < maxLevel; i++) ...[
          if (i > 0) const SizedBox(width: AppSpacing.x1),
          AnimatedContainer(
            duration: AppMotion.fast,
            width: _dotSize,
            height: _dotSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < filled ? colors.selectionFill : colors.control,
            ),
          ),
        ],
      ],
    );
  }
}

/// Full-width entry row into the climate schedule editor. Distinct from
/// [SoftActionTile]: this row always carries a trailing chevron, which
/// `SoftActionTile` has no slot for and should not grow just for this one
/// caller.
class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final enabled = onPressed != null;
    final foreground = enabled ? colors.ink : colors.inkSubtle;
    return Material(
      color: colors.control,
      borderRadius: AppRadii.mdRadius,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadii.mdRadius,
        child: SizedBox(
          height: AppSizes.actionRowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
            child: Row(
              children: [
                Icon(Icons.schedule, size: AppSizes.iconMd, color: foreground),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: Text(
                    label,
                    style: AppText.bodyStrong.copyWith(color: foreground),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: AppSizes.iconMd,
                  color: foreground,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Steering-wheel glyph. Not part of Flutter's bundled Material Icons font, so
/// it is drawn the same way [BatteryAndroidFrameAlertIcon] is: ink over a
/// transparent square, tinted from the current [IconTheme] or theme ink.
class SteeringWheelIcon extends StatelessWidget {
  const SteeringWheelIcon({this.size = AppSizes.iconMd, this.color, super.key});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final colors = AppThemeColors.of(context);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _SteeringWheelPainter(
          color: color ?? iconTheme.color ?? colors.ink,
        ),
      ),
    );
  }
}

class _SteeringWheelPainter extends CustomPainter {
  const _SteeringWheelPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final strokeWidth = size.shortestSide * 0.1;
    final ringPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius - strokeWidth / 2, ringPaint);

    final hubRadius = radius * 0.24;
    canvas.drawCircle(center, hubRadius, Paint()..color = color);

    final spokeOuter = radius - strokeWidth;
    for (final turns in [0.25, 0.25 + 1 / 3, 0.25 - 1 / 3]) {
      final angle = turns * 2 * math.pi;
      final dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + dir * hubRadius,
        center + dir * spokeOuter,
        ringPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_SteeringWheelPainter oldDelegate) =>
      oldDelegate.color != color;
}
