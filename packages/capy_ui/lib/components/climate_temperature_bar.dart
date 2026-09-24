import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// The always-dark climate strip: one [ClimateZonePill] per climate zone,
/// pushed to opposite ends of the bar.
///
/// The strip itself paints nothing. On the reference head unit the zone
/// controls are two separate pills floating on the bezel, not the two ends of
/// one long bar — so the ground behind them is the bezel showing through, and
/// [centerChild] fills the space between with whatever else that row carries.
///
/// This is the one component in `lib/ui/` that deliberately ignores the theme
/// system. It reads [AppColors] constants directly rather than
/// `AppThemeColors.of(context)`, so it renders identically in every one of the
/// app's themes, the way the reference head unit's climate strip does not
/// change with the cabin's day/night setting. Do not thread `AppThemeColors`
/// through this widget or its private children.
class ClimateTemperatureBar extends StatelessWidget {
  const ClimateTemperatureBar({
    required this.driverValue,
    required this.driverDecreaseLabel,
    required this.driverIncreaseLabel,
    required this.passengerValue,
    required this.passengerDecreaseLabel,
    required this.passengerIncreaseLabel,
    this.driverCaption,
    this.passengerCaption,
    this.driverFanActive = true,
    this.passengerFanActive = true,
    this.onDriverDecrease,
    this.onDriverIncrease,
    this.onPassengerDecrease,
    this.onPassengerIncrease,
    this.centerChild,
    super.key,
  });

  /// Pre-formatted driver-zone reading — `21.5`, or `LO` at the vehicle floor.
  /// A numeric reading gets a `°` attached; a floor/ceiling label does not.
  final String driverValue;

  /// The mode line under the driver reading — `AUTO`, `OFF`. Null draws no
  /// line at all, which is a third real state on the reference unit and not a
  /// placeholder for a missing one.
  final String? driverCaption;

  /// Whether the driver fan is running. It fills the fan glyph; a stopped fan
  /// is drawn as an outline.
  final bool driverFanActive;

  final String driverDecreaseLabel;
  final String driverIncreaseLabel;
  final VoidCallback? onDriverDecrease;
  final VoidCallback? onDriverIncrease;

  /// The passenger twin of the driver fields above.
  final String passengerValue;
  final String? passengerCaption;
  final bool passengerFanActive;
  final String passengerDecreaseLabel;
  final String passengerIncreaseLabel;
  final VoidCallback? onPassengerDecrease;
  final VoidCallback? onPassengerIncrease;

  /// Optional content between the two pills — the shortcut row on the
  /// reference unit. Left null, the bar keeps the space as a plain gap.
  final Widget? centerChild;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('climate-temperature-bar-surface'),
      height: AppSizes.climateBarHeight,
      child: Row(
        children: [
          ClimateZonePill(
            zoneKeyPrefix: 'driver',
            value: driverValue,
            caption: driverCaption,
            fanActive: driverFanActive,
            decreaseLabel: driverDecreaseLabel,
            increaseLabel: driverIncreaseLabel,
            onDecrease: onDriverDecrease,
            onIncrease: onDriverIncrease,
          ),
          Expanded(child: centerChild ?? const SizedBox.shrink()),
          ClimateZonePill(
            zoneKeyPrefix: 'passenger',
            value: passengerValue,
            caption: passengerCaption,
            fanActive: passengerFanActive,
            decreaseLabel: passengerDecreaseLabel,
            increaseLabel: passengerIncreaseLabel,
            onDecrease: onPassengerDecrease,
            onIncrease: onPassengerIncrease,
          ),
        ],
      ),
    );
  }
}

/// One climate zone: a grey pill holding a blue decrease chevron, the reading
/// with its fan glyph, an optional mode line, and a red increase chevron.
///
/// Both zones draw this same shape rather than a mirrored one — the reference
/// unit repeats the cluster verbatim on each side instead of reflecting it.
///
/// The two chevrons are the only coloured things here. Cool left, warm right,
/// which is what lets the reading itself stay plain white: the direction is
/// carried by the control, so the number does not have to carry it too. A
/// stepper callback left null disables that chevron rather than hiding it: the
/// caller states a real vehicle limit; this widget never invents one.
class ClimateZonePill extends StatelessWidget {
  const ClimateZonePill({
    required this.zoneKeyPrefix,
    required this.value,
    required this.decreaseLabel,
    required this.increaseLabel,
    this.caption,
    this.fanActive = true,
    this.onDecrease,
    this.onIncrease,
    super.key,
  });

  /// Identifies this zone in the two chevron `Key`s below (`driver`,
  /// `passenger`), so a test can address one button unambiguously.
  final String zoneKeyPrefix;

  final String value;
  final String? caption;
  final bool fanActive;
  final String decreaseLabel;
  final String increaseLabel;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    final caption = this.caption;
    return Container(
      key: Key('climate-zone-pill-$zoneKeyPrefix'),
      height: AppSizes.climateBarHeight,
      decoration: const BoxDecoration(
        color: AppColors.climatePillSurface,
        borderRadius: AppRadii.fullRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Chevron(
            key: Key('climate-temperature-bar-$zoneKeyPrefix-decrease'),
            icon: Icons.keyboard_arrow_down_rounded,
            color: AppColors.climateBarCool,
            label: decreaseLabel,
            onPressed: onDecrease,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        climateZoneReading(value),
                        style: AppText.metricSm.copyWith(
                          color: AppColors.climateBarOnSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.x1),
                      FanIcon(
                        size: AppSizes.iconMd,
                        color: AppColors.climateBarOnSurface,
                        filled: fanActive,
                      ),
                    ],
                  ),
                  if (caption != null)
                    Text(
                      caption,
                      style: AppText.caption.copyWith(
                        color: AppColors.climateBarOnSurfaceMuted,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        height: 1.1,
                      ),
                    ),
                ],
              ),
            ),
          ),
          _Chevron(
            key: Key('climate-temperature-bar-$zoneKeyPrefix-increase'),
            icon: Icons.keyboard_arrow_up_rounded,
            color: AppColors.climateBarWarm,
            label: increaseLabel,
            onPressed: onIncrease,
          ),
        ],
      ),
    );
  }
}

/// One chevron button, as tall as the pill so it needs no larger hit box of
/// its own.
class _Chevron extends StatelessWidget {
  const _Chevron({
    required this.icon,
    required this.color,
    required this.label,
    this.onPressed,
    super.key,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: SizedBox.square(
              dimension: AppSizes.climateBarHeight,
              child: Icon(
                icon,
                size: AppSizes.iconLg,
                color: enabled ? color : color.withValues(alpha: 0.35),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Formats a zone reading for the pill: a number gets `°` attached, a
/// floor/ceiling label (`LO`, `HI`) or an unreported `--` does not.
String climateZoneReading(String value) {
  return double.tryParse(value) == null ? value : '$value°';
}

/// The four-blade fan glyph beside a climate reading.
///
/// A thin naming wrapper over `Icons.toys`, which is the bundled four-blade
/// fan despite what it is called. The wrapper exists for that reason alone:
/// `Icons.toys` at a call site reads as a mistake, and the next person to see
/// it would swap it for `Icons.air` — three wind lines, which say moving air
/// rather than a fan that is or is not turning.
///
/// [filled] is the distinction the reference draws between a running fan and a
/// stopped one. It is a real state of the climate system, not a decoration, so
/// it picks the glyph rather than a colour applied to one.
class FanIcon extends StatelessWidget {
  const FanIcon({
    required this.color,
    this.size = AppSizes.iconMd,
    this.filled = true,
    super.key,
  });

  final Color color;
  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Icon(
      filled ? Icons.toys : Icons.toys_outlined,
      size: size,
      color: color,
    );
  }
}
