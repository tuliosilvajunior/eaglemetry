import 'package:flutter/material.dart';

import '../../core/telemetry_api.dart';
import '../../core/telemetry_format.dart';
import '../../screens_v2/charge_cost_editor.dart';
import '../../design_system/design_system.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/telemetry_map_panel.dart';

/// Presentation model for a charging session row, decoupled from the native
/// `SessionRecord` DTO. Mirrors `TripSessionDisplay`.
class ChargingSessionDisplay {
  const ChargingSessionDisplay({
    required this.id,
    required this.status,
    required this.statusColor,
    required this.startedLabel,
    required this.windowLabel,
    required this.durationLabel,
    required this.plugLabel,
    required this.socRange,
    required this.socDelta,
    required this.odometerRange,
    required this.odometerDelta,
    required this.energyLabel,
    required this.powerLabel,
    required this.costLabel,
    required this.endReason,
    required this.updatedLabel,
    required this.session,
    this.isSample = false,
  });

  factory ChargingSessionDisplay.fromSession(
    SessionRecord session,
    AppLocalizations loc, {
    double? defaultCostPerKwh,
  }) {
    final connectedAt = dateTimeFromMillis(session.startedAtUtcMillis);
    final startedAt = dateTimeFromMillis(session.chargeStartedAtUtcMillis);
    final endedAt = dateTimeFromMillis(
      session.plugDisconnectedAtUtcMillis ?? session.chargeEndedAtUtcMillis,
    );
    final displayStart = startedAt ?? connectedAt;
    final displayEnd = endedAt;
    final duration =
        durationFromMillis(sessionReadingDurationMillis(session)) ??
        boundedDurationBetween(
          displayStart,
          displayEnd,
          maximum: const Duration(days: 31),
        );
    return ChargingSessionDisplay(
      id: session.id,
      status: chargeStatusLabel(session.status, loc),
      statusColor: chargeStatusColor(session.status, session.endReason),
      startedLabel: displayStart == null
          ? '--'
          : formatChargeEventDate(displayStart, loc),
      windowLabel: formatWindow(displayStart, displayEnd),
      durationLabel: chargeFormatElapsed(duration, active: displayEnd == null),
      plugLabel: chargePlugLabel(session.plugType, loc),
      socRange: socRangeLabel(
        session.startSoc.displayValue,
        session.endSoc.displayValue,
      ),
      socDelta: socDeltaLabel(
        session.startSoc.displayValue,
        session.endSoc.displayValue,
      ),
      odometerRange: chargeOdometerRange(
        session.startOdometer.displayValue,
        session.endOdometer.displayValue,
      ),
      odometerDelta: chargeOdometerDelta(
        session.startOdometer.displayValue,
        session.endOdometer.displayValue,
      ),
      energyLabel: chargeEnergyLabel(
        sessionReadingDeliveredKwh(session).displayValue,
      ),
      powerLabel: chargePowerLabel(session.startPowerKw),
      costLabel: chargeCostLabel(
        energyKwh: sessionReadingDeliveredKwh(session).displayValue,
        costPerKwh: session.costPerKwh ?? defaultCostPerKwh,
        paidAmount: session.paidAmount,
        currency: chargeCostCurrencyOf(session, fallback: 'BRL'),
        localeName: loc.localeName,
      ),
      endReason: session.endReason != null
          ? chargeEndReasonLabel(session.endReason!, loc)
          : chargeFallbackEndReason(session.status, loc),
      updatedLabel: chargeFormatUpdated(session.updatedAtUtcMillis),
      session: session,
    );
  }

  final String id;
  final String status;
  final Color statusColor;
  final String startedLabel;
  final String windowLabel;
  final String durationLabel;
  final String plugLabel;
  final String socRange;
  final String socDelta;
  final String odometerRange;
  final String odometerDelta;
  final String energyLabel;
  final String powerLabel;
  final String costLabel;
  final String endReason;
  final String updatedLabel;
  final SessionRecord? session;
  final bool isSample;

  String get shortId {
    if (id.length <= 12) return id;
    return '${id.substring(0, 8)}...${id.substring(id.length - 4)}';
  }
}

/// Estados em que a sessão ainda está acontecendo.
///
/// `ENDED_WAITING_DISCONNECT` conta: a carga terminou, mas o plugue continua no
/// carro e o detector ainda pode reabrir a sessão — tratá-la como histórico
/// produziria uma linha encerrada que volta a mudar sozinha.
bool isLiveChargeStatus(String status) {
  switch (status.toUpperCase()) {
    case 'CHARGING':
    case 'PLUG_CONNECTED':
    case 'ENDED_WAITING_DISCONNECT':
      return true;
    default:
      return false;
  }
}

String chargeStatusLabel(String status, AppLocalizations loc) {
  switch (status.toUpperCase()) {
    case 'CHARGING':
      return loc.statusCharging;
    case 'PLUG_CONNECTED':
      return loc.statusConnected;
    case 'PLUG_DISCONNECTED':
      return loc.statusDisconnected;
    case 'ENDED':
      return loc.statusComplete;
    default:
      return status.toUpperCase();
  }
}

Color chargeStatusColor(String status, String? endReason) {
  final upperStatus = status.toUpperCase();
  final upperReason = endReason?.toUpperCase() ?? '';
  if (upperStatus == 'CHARGING') return AutomotiveColors.secondary;
  if (upperStatus == 'PLUG_CONNECTED') return AutomotiveColors.warning;
  if (upperReason.contains('ERROR') || upperReason.contains('INTERRUPT')) {
    return AutomotiveColors.error;
  }
  if (upperStatus == 'ENDED') return AutomotiveColors.onSurfaceVariant;
  return AutomotiveColors.tertiary;
}

String chargePlugLabel(int? plugType, AppLocalizations loc) {
  switch (plugType) {
    case 605225491:
      return loc.plugAc;
    case 605225492:
      return loc.plugDc;
    case 605225499:
      return loc.plugIntegration;
    case 605225490:
      return loc.plugNone;
    case null:
      return '--';
    default:
      return 'RAW $plugType';
  }
}

bool isDcChargePlugType(int? plugType) => plugType == 605225492;

String formatWindow(DateTime? start, DateTime? end) {
  if (start == null) return '--';
  final startText = '${twoDigits(start.hour)}:${twoDigits(start.minute)}';
  final endText = end == null
      ? '--:--'
      : '${twoDigits(end.hour)}:${twoDigits(end.minute)}';
  return '$startText - $endText';
}

String chargeFormatDuration(DateTime? start, DateTime? end) {
  return chargeFormatElapsed(
    durationBetween(start, end),
    active: start != null && end == null,
  );
}

String chargeFormatElapsed(Duration? duration, {bool active = false}) {
  if (duration == null || duration.isNegative) return '--';
  final minutes = duration.inMinutes;
  if (active && minutes < 1) return 'active';
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  if (hours == 0) return '${remainingMinutes}m';
  return '${hours}h ${remainingMinutes}m';
}

String chargeFormatUpdated(int millis) {
  final updated = dateTimeFromMillis(millis);
  if (updated == null) return 'updated --';
  return 'updated ${formatDateTime(updated)}';
}

String chargeOdometerRange(double? start, double? end) {
  final value = end ?? start;
  if (value == null) return '--';
  return '${value.toStringAsFixed(1)} km';
}

String chargeOdometerDelta(double? start, double? end) {
  if (start == null || end == null) return '--';
  final delta = end - start;
  final sign = delta >= 0 ? '+' : '';
  return '$sign${delta.toStringAsFixed(1)} km';
}

String chargePowerLabel(double? value) {
  if (value == null) return '--';
  return '${value.toStringAsFixed(1)} kW';
}

String chargeEnergyLabel(double? value) {
  if (value == null) return '--';
  return value.toStringAsFixed(1);
}

String chargeEndReasonLabel(String reason, AppLocalizations loc) {
  switch (reason.toUpperCase()) {
    case 'IN_PROGRESS':
      return loc.endReasonInProgress;
    case 'WAITING_FOR_CHARGE':
      return loc.endReasonWaitingCharge;
    case 'COMPLETED':
      return loc.endReasonCompleted;
    case 'PLUG_DISCONNECTED':
      return loc.endReasonPlugDisconnected;
    case 'WAITING_FOR_POWER':
      return loc.endReasonWaitingPower;
    default:
      return reason;
  }
}

String chargeFallbackEndReason(String status, AppLocalizations loc) {
  switch (status.toUpperCase()) {
    case 'CHARGING':
      return loc.endReasonInProgress;
    case 'PLUG_CONNECTED':
      return loc.endReasonWaitingCharge;
    default:
      return '--';
  }
}

List<TelemetryMapPoint> chargeLocationPoint(SessionRecord session) {
  final latitude = session.startLatitude;
  final longitude = session.startLongitude;
  if (latitude == null || longitude == null) return const [];
  return [
    TelemetryMapPoint(
      latitude: latitude,
      longitude: longitude,
      altitudeM: session.startAltitudeM,
      accuracyM: session.startGpsAccuracyM,
    ),
  ];
}

double chargeMinimumPadding(String unit) {
  switch (unit) {
    case 'V':
      return 5;
    case 'A':
      return 2;
    case 'kW':
      return 0.5;
    default:
      return 1;
  }
}

double chargeMinimumRange(String unit) {
  switch (unit) {
    case 'V':
      return 20;
    case 'A':
      return 10;
    case 'kW':
      return 5;
    default:
      return 10;
  }
}

// Charge math (energy, average power, per-frame power) lives in
// lib/core/charge_metrics.dart, shared with the mock detail path.
