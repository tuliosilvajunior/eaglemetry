import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../design_system/design_system.dart';
import '../l10n/app_localizations.dart';

export 'package:telemetry_core/telemetry_core.dart' show compassBearingLabel;

/// Shared telemetry formatting and parsing helpers.
///
/// These were duplicated as private free functions across the session/charge
/// screens. They are pure (no widget state) aside from reading adaptive
/// [AutomotiveColors] and localized [AppLocalizations] strings.
String twoDigits(int value) => value.toString().padLeft(2, '0');

DateTime? dateTimeFromMillis(int? millis) {
  if (millis == null || millis <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
}

Duration? durationBetween(DateTime? start, DateTime? end) {
  if (start == null) return null;
  final effectiveEnd = end ?? DateTime.now();
  final duration = effectiveEnd.difference(start);
  if (duration.isNegative) return null;
  return duration;
}

Duration? boundedDurationBetween(
  DateTime? start,
  DateTime? end, {
  required Duration maximum,
}) {
  final duration = durationBetween(start, end);
  if (duration == null || duration > maximum) return null;
  return duration;
}

Duration? durationFromMillis(int? millis) {
  if (millis == null || millis < 0) return null;
  return Duration(milliseconds: millis);
}

String formatDateTime(DateTime value) {
  return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)} '
      '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
}

String formatTripListDateTime(DateTime value) {
  return '${twoDigits(value.day)}/${twoDigits(value.month)}/${value.year} '
      'às ${twoDigits(value.hour)}:${twoDigits(value.minute)}';
}

String formatSessionEventDate(DateTime value, AppLocalizations loc) {
  final locale = loc.localeName;
  final pattern = locale.toLowerCase().startsWith('pt')
      ? "EEEE d 'de' MMMM"
      : 'EEEE, MMMM d';
  final formatted = DateFormat(pattern, locale).format(value);
  return toBeginningOfSentenceCase(formatted, locale) ?? formatted;
}

String formatChargeEventDate(DateTime value, AppLocalizations loc) {
  return formatSessionEventDate(value, loc);
}

/// Clock-style duration: `mm:ss` under an hour, `hh:mm:ss` from one hour up.
String formatDuration(Duration? duration) {
  if (duration == null) return '--';
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours == 0) return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}';
}

String formatUpdated(int millis) {
  final updated = dateTimeFromMillis(millis);
  if (updated == null) return '--';
  return formatDateTime(updated);
}

String statusLabel(String status, AppLocalizations loc) {
  switch (status.toUpperCase()) {
    case 'ACTIVE':
      return loc.tripStatusActive;
    case 'ENDED':
      return loc.statusComplete;
    case 'PENDING_END':
      return loc.tripStatusPendingEnd;
    default:
      return status.toUpperCase();
  }
}

Color statusColorFor(String status, String? endReason) {
  final upperStatus = status.toUpperCase();
  final upperReason = endReason?.toUpperCase() ?? '';
  if (upperStatus == 'ACTIVE') return AutomotiveColors.secondary;
  if (upperReason.contains('CANCEL') || upperReason.contains('ERROR')) {
    return AutomotiveColors.warning;
  }
  if (upperStatus == 'ENDED') return AutomotiveColors.tertiary;
  return AutomotiveColors.onSurfaceVariant;
}

double? distanceBetween(double? start, double? end) {
  if (start == null || end == null) return null;
  final value = end - start;
  if (value < 0) return null;
  return value;
}

String distanceLabelFor(double? distance, AppLocalizations loc) {
  if (distance == null) return '--';
  return '${distance.toStringAsFixed(1)} ${loc.unitKm}';
}

String efficiencyLabel(double? value) {
  if (value == null) return '--';
  return '${value.toStringAsFixed(0)} Wh/km';
}

String rangePerEnergyLabel(double? value) {
  if (value == null) return '--';
  return '${value.toStringAsFixed(1)} km/kWh';
}

String energyLabel(double? value) {
  if (value == null) return '--';
  return '${value.toStringAsFixed(2)} kWh';
}

String liveNumber(double? value, String unit, {required int decimals}) {
  if (value == null) return '--';
  return '${value.toStringAsFixed(decimals)} $unit';
}

double? liveEfficiencyWhPerKm(double netEnergyKwh, double distanceKm) {
  if (distanceKm < 0.01 || netEnergyKwh <= 0) return null;
  return (netEnergyKwh * 1000) / distanceKm;
}

double? liveKmPerKwh(double netEnergyKwh, double distanceKm) {
  if (distanceKm < 0.01 || netEnergyKwh <= 0) return null;
  return distanceKm / netEnergyKwh;
}

double? mapDouble(Map<String, Object?>? map, String key) {
  if (map == null) return null;
  return objectAsDouble(map[key]);
}

String? mapText(Map<String, Object?>? map, String key) {
  if (map == null) return null;
  return map[key]?.toString();
}

double? objectAsDouble(Object? value) {
  if (value is num) return value.toDouble();
  return value?.toString().replaceAll(',', '.').trim().isEmpty == true
      ? null
      : double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
}

String speedLabelFor(
  double? distance,
  Duration? duration,
  AppLocalizations loc,
) {
  if (distance == null || duration == null || duration.inSeconds <= 0) {
    return '--';
  }
  final hours = duration.inSeconds / 3600;
  return '${(distance / hours).round()} ${loc.unitKmh}';
}

/// One speed the car reported, to the nearest km/h.
///
/// Distinct from [speedLabelFor], which divides a distance by a duration and
/// therefore answers an average. This one prints a reading.
String speedKmhLabel(double? kmh, AppLocalizations loc) {
  if (kmh == null || !kmh.isFinite) return '--';
  return '${kmh.round()} ${loc.unitKmh}';
}

String socRangeLabel(double? start, double? end) {
  final startText = start == null ? '--' : '${start.toStringAsFixed(1)}%';
  final endText = end == null ? '--' : '${end.toStringAsFixed(1)}%';
  return '$startText -> $endText';
}

String ambientTempLabel(double? celsius) {
  if (celsius == null) return '--';
  return '${celsius.toStringAsFixed(1)}°C';
}

String ambientTempRangeLabel(double? start, double? end) {
  if (start == null && end == null) return '--';
  return '${ambientTempLabel(start)} -> ${ambientTempLabel(end)}';
}

/// Climb, as a whole metre. Null stays `--`.
String altitudeGainLabel(double? metres) {
  if (metres == null || !metres.isFinite) return '--';
  return '+${metres.round()} m';
}

/// Whole degrees for a `TiltGauge` readout (`3°`, `-2°`, `0°`).
///
/// Rounds to whole degrees, because that is the resolution a tilt reading is
/// read at, and normalizes a rounded-away negative so a level car never shows
/// `-0°`.
String tiltAngleLabel(double? degrees) {
  if (degrees == null || !degrees.isFinite) return '--';
  final rounded = degrees.roundToDouble();
  return '${rounded == 0 ? 0 : rounded.toInt()}°';
}

String socDeltaLabel(double? start, double? end) {
  if (start == null || end == null) return '--';
  final delta = end - start;
  return '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}%';
}

String odometerLabelFor(double? value, AppLocalizations loc) {
  if (value == null) return '--';
  return '${value.toStringAsFixed(1)} ${loc.unitKm}';
}

String gearLabelFor(int? value, AppLocalizations loc) {
  if (value == null) return '--';
  if ((value & 0x8) != 0) return loc.gearD;
  if ((value & 0x4) != 0) return loc.gearP;
  if ((value & 0x2) != 0) return loc.gearR;
  if ((value & 0x1) != 0) return loc.gearN;
  return 'RAW $value';
}

String fallbackEndReason(String status, AppLocalizations loc) {
  switch (status.toUpperCase()) {
    case 'ACTIVE':
      return loc.tripEndReasonInProgress;
    case 'PENDING_END':
      return loc.tripEndReasonWaitingIdle;
    default:
      return '--';
  }
}

double paddedMinY(List<FlSpot> spots, double floor, double ceiling) {
  if (spots.isEmpty) return floor;
  final minValue = spots.fold<double>(
    double.infinity,
    (min, spot) => spot.y < min ? spot.y : min,
  );
  final maxValue = spots.fold<double>(
    double.negativeInfinity,
    (max, spot) => spot.y > max ? spot.y : max,
  );
  final range = (maxValue - minValue).abs();
  final padding = range <= 0 ? 1.0 : (range * 0.12).clamp(1.0, 30.0);
  return (minValue - padding).clamp(floor, ceiling).toDouble();
}

double paddedMaxY(List<FlSpot> spots, double minimum, double ceiling) {
  if (spots.isEmpty) return minimum;
  final minValue = spots.fold<double>(
    double.infinity,
    (min, spot) => spot.y < min ? spot.y : min,
  );
  final maxValue = spots.fold<double>(
    double.negativeInfinity,
    (max, spot) => spot.y > max ? spot.y : max,
  );
  final range = (maxValue - minValue).abs();
  final padding = range <= 0 ? 1.0 : (range * 0.12).clamp(1.0, 30.0);
  return (maxValue + padding).clamp(minimum, ceiling).toDouble();
}
