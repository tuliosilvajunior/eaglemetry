import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/charge_graph_data.dart';
import '../../core/telemetry_api.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

/// Window the chart plots: the whole plug-in, charge and idle alike.
///
/// This used to stop where `chargeEndedAtUtcMillis` said the charge did, to
/// keep a car left connected from trailing hours of empty columns. Those hours
/// are worth seeing — they are time spent sitting at the limit — and
/// [ChargePhase] now tells them apart from charging, so the window no longer
/// has to hide them. `buildChargeGraphData` trims a runaway tail on its own.
///
/// The charge timestamps are also the pair a reboot could rewrite, and
/// trusting them once reported a fifteen-hour charge as ninety-five seconds.
/// The span is bounded by the same plausibility ceiling the session duration
/// uses: a plug-in stamp years out of date plots nothing instead of 22000
/// hours of columns. Plug-in and plug-out are written once each and never
/// reconciled against one another.
Duration? chargeWindow(SessionRecord session) {
  final start = session.startedAtUtcMillis;
  final end = session.plugDisconnectedAtUtcMillis;
  if (end == null || end <= start) return null;
  final span = end - start;
  if (span > kMaxChargeWallDurationMillis) return null;
  return Duration(milliseconds: span);
}

/// Wall-clock time the charge limit was first met, or null if it never was.
DateTime? chargeTargetReachedAt(ChargeDetailReading detail) {
  if (detail.targetReachedAtUtcMillis.isEmpty) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    detail.targetReachedAtUtcMillis.reduce(math.min),
  );
}

/// How long the session actually spent charging.
///
/// Distinct from the plotted window now that the window covers idle time too:
/// a fifteen-hour plug-in that charged for thirteen should report thirteen.
///
/// Summed over the stored minutes rather than measured end to end, because a
/// session can stop and start again — a car woken on the plug tops up and is
/// cut once more — and the idle hours between those bursts are not charging.
///
/// Each minute states how many of its seconds delivered energy, so this is a
/// sum of measured time and not a count of plotted columns. Reading it off the
/// gaps between points instead loses the last minute of every charge, because
/// the last point has no successor to measure against.
Duration? chargingDuration(SessionRecord session, ChargeDetailReading detail) {
  var seconds = 0.0;
  for (final interval in detail.series.intervals) {
    final delivered = interval.delivered.displayValue;
    if (delivered == null) continue;
    final covered = interval.deliveredCoveredSeconds;
    if (covered <= 0) continue;
    final kw = delivered / 1000.0 / (covered / 3600.0);
    if (kw <= chargeIdlePowerKw) continue;
    seconds += covered;
  }
  if (seconds <= 0) return chargeSessionDuration(session);
  return Duration(seconds: seconds.round());
}

Duration? chargeSessionDuration(SessionRecord session) {
  final stored = sessionReadingDurationMillis(session);
  if (stored != null && stored >= 0) return Duration(milliseconds: stored);
  final start = session.chargeStartedAtUtcMillis ?? session.startedAtUtcMillis;
  final end =
      session.chargeEndedAtUtcMillis ?? session.plugDisconnectedAtUtcMillis;
  if (end == null || end < start) return null;
  return Duration(milliseconds: end - start);
}

bool chargeSessionIsActive(SessionRecord session) {
  return const {
    'CHARGING',
    'PLUG_CONNECTED',
    'ENDED_WAITING_DISCONNECT',
  }.contains(session.status.toUpperCase());
}

String chargeTimeOfDayLabel(BuildContext context, DateTime value) {
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(value),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
}

String chargeDurationLabel(AppLocalizations loc, Duration? duration) {
  if (duration == null || duration.isNegative) return '--';
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  return hours == 0
      ? loc.v2ChargeGraphDurationMinutes(minutes)
      : loc.v2ChargeGraphDurationHoursMinutes(hours, minutes);
}

double? usableChargeEnergy(double? value) {
  if (value == null || !value.isFinite || value < 0) return null;
  return value;
}

/// A failed or empty graph/session read, drawn the one way.
class ChargeGraphMessage extends StatelessWidget {
  const ChargeGraphMessage({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(message, style: AppText.label, textAlign: TextAlign.center),
  );
}
