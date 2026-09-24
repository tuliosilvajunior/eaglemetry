import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

/// The label the reader sees for one [ContinuousLabel], reusing the same
/// words the `Drive | Parked` control already uses for drive and parked so
/// the vocabulary stays one thing across the app.
String continuousLabelText(AppLocalizations loc, ContinuousLabel label) =>
    switch (label) {
      ContinuousLabel.trip => loc.energyModeDrive,
      ContinuousLabel.parked => loc.energyModeParked,
      ContinuousLabel.charge => loc.energyStateCharge,
      ContinuousLabel.poweredOn => loc.energyStatePoweredOn,
    };

/// What one column of an energy chart holds, as the reader sees it.
///
/// Shared rather than written per screen. The live monitor and a finished
/// drive's detail plot the same buckets from the same accumulator, so a second
/// copy of this would be a second answer to the same question — and the one
/// that is read less often is the one that stops being corrected.
///
/// The rows follow the stack: named shares before the unnamed remainder, in the
/// order they are drawn from the axis upward, then regeneration, then the
/// interval itself. Climate is **absent** rather than zero when the car did not
/// report it, so the reader is never told the heater drew nothing over a minute
/// nobody measured.
class EnergyBucketTooltip extends StatelessWidget {
  const EnergyBucketTooltip({
    required this.bucket,
    this.open = false,
    this.isParked = false,
    this.stateLabel,
    this.estimated = false,
    this.relativeStartMinutes,
    this.relativeEndMinutes,
    super.key,
  });

  final EnergyBucket bucket;

  /// Whether this is the interval still being filled. A finished session has
  /// none, which is why it is not read off the bucket.
  final bool open;

  /// Whether the session/vehicle was parked during this interval.
  final bool isParked;

  /// Which of the four CONTINUOUS states this minute was in, on the "Since
  /// power on" window. Null everywhere else — a trip or a parked chart is
  /// already known to be one state throughout, so naming it minute by minute
  /// would answer a question the reader did not ask.
  ///
  /// When given, the tooltip states the name and rides the minute's start
  /// and end SOC along as a cross-check, per issue 199/208.
  final ContinuousLabel? stateLabel;

  /// Whether this minute is the sleep-gap reconstruction rather than a
  /// measured reading. Ignored when [stateLabel] is null — a trip or a
  /// parked chart never carries an estimated minute. See issue 199/211.
  final bool estimated;

  /// Minutes since the series start, shown instead of the wall clock while
  /// the series still waits for the boot's anchor. Both set or both null:
  /// a half-relative window would mix two dishonest references.
  final int? relativeStartMinutes;

  /// End of the relative window, in minutes since the series start.
  final int? relativeEndMinutes;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final energy = readEnergyComposition([bucket]);
    final relativeStart = relativeStartMinutes;
    final relativeEnd = relativeEndMinutes;
    final window = relativeStart != null && relativeEnd != null
        ? '${loc.energyAxisRelativeMinutes(relativeStart)}–${loc.energyAxisRelativeMinutes(relativeEnd)}'
        : '${_timeLabel(context, bucket.start)}–${_timeLabel(context, bucket.end)}';
    final label = stateLabel;
    final labelText = label == null
        ? null
        : estimated
        ? '${continuousLabelText(loc, label)} · ${loc.liveChargeBadgeEstimate}'
        : continuousLabelText(loc, label);
    final socRow = label == null ? null : _socRow(loc, bucket);

    if (isParked) {
      final watts = energy.seconds > 0
          ? energy.drawn * 3600 / energy.seconds
          : null;
      return ChartTooltip(
        side: ChartTooltipSide.none,
        value: watts?.round().toString() ?? '--',
        unit: loc.unitWatt,
        rows: [
          if (labelText != null) ChartTooltipRow(label: labelText),
          if (energy.divided && energy.climate > 0)
            ChartTooltipRow(
              label: loc.energyClimate,
              value: _kwh(loc, energy.climate, decimals: 3),
              color: AppThemeColors.of(context).energy.drawSoft,
            ),
          if (energy.system > 0)
            ChartTooltipRow(
              label: loc.energyAuxiliary,
              value: _kwh(loc, energy.system, decimals: 3),
              color: AppThemeColors.of(context).energy.drawSubtle,
            ),
          if (bucket.regeneratedWh > 0)
            ChartTooltipRow(
              label: '+${_kwh(loc, bucket.regeneratedWh, decimals: 3)}',
              color: AppThemeColors.of(context).energy.gain,
            ),
          if (bucket.deliveredWh > 0)
            ChartTooltipRow(
              label: '+${_kwh(loc, bucket.deliveredWh, decimals: 3)}',
              color: AppThemeColors.of(context).energy.gain,
            ),
          ChartTooltipRow(label: window),
          ?socRow,
        ],
      );
    }

    return ChartTooltip(
      side: ChartTooltipSide.none,
      value: (bucket.drawnWh / 1000).toStringAsFixed(2),
      unit: loc.unitKwh,
      rows: [
        if (labelText != null) ChartTooltipRow(label: labelText),
        if (energy.divided && energy.climate > 0)
          ChartTooltipRow(
            label: loc.energyClimate,
            value: _kwh(loc, energy.climate),
            color: AppThemeColors.of(context).energy.drawSoft,
          ),
        if (energy.system > 0)
          ChartTooltipRow(
            label: loc.energyAuxiliary,
            value: _kwh(loc, energy.system),
            color: AppThemeColors.of(context).energy.drawSubtle,
          ),
        if (bucket.regeneratedWh > 0)
          ChartTooltipRow(
            label: '+${_kwh(loc, bucket.regeneratedWh)}',
            color: AppThemeColors.of(context).energy.gain,
          ),
        if (bucket.deliveredWh > 0)
          ChartTooltipRow(
            label: '+${_kwh(loc, bucket.deliveredWh)}',
            color: AppThemeColors.of(context).energy.gain,
          ),
        ChartTooltipRow(
          label: open ? '$window · ${loc.energyBarOpen}' : window,
        ),
        ?socRow,
      ],
    );
  }

  /// Start and end SOC, together, or null when the buckets never carried
  /// either — a cross-check against the integral above it, not a second
  /// measurement of it.
  static ChartTooltipRow? _socRow(AppLocalizations loc, EnergyBucket bucket) {
    final start = bucket.startSoc;
    final end = bucket.endSoc;
    if (start == null && end == null) return null;
    final startText = start == null ? '--' : '${start.round()}%';
    final endText = end == null ? '--' : '${end.round()}%';
    return ChartTooltipRow(label: '$startText → $endText SOC');
  }

  static String _kwh(AppLocalizations loc, double wh, {int decimals = 2}) =>
      '${(wh / 1000).toStringAsFixed(decimals)} ${loc.unitKwh}';

  static String _timeLabel(BuildContext context, DateTime value) {
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(value),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }
}
