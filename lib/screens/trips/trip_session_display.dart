import 'package:flutter/material.dart';

import '../../core/telemetry_api.dart';
import '../../core/telemetry_format.dart';
import '../../l10n/app_localizations.dart';

class TripSessionDisplay {
  const TripSessionDisplay({
    required this.session,
    required this.id,
    required this.status,
    required this.statusColor,
    required this.startLabel,
    required this.dateLabel,
    required this.windowLabel,
    required this.durationLabel,
    required this.distanceLabel,
    required this.speedLabel,
    required this.socRange,
    required this.socDelta,
    required this.odometerLabel,
    required this.gearLabel,
    required this.endReason,
    required this.updatedLabel,
    this.startSoc,
    this.endSoc,
  });

  factory TripSessionDisplay.fromSession(
    SessionRecord session,
    AppLocalizations loc,
  ) {
    final startedAt = dateTimeFromMillis(session.startedAtUtcMillis);
    final endedAt = dateTimeFromMillis(session.endedAtUtcMillis);
    final duration =
        durationFromMillis(sessionReadingDurationMillis(session)) ??
        boundedDurationBetween(
          startedAt,
          endedAt,
          maximum: const Duration(hours: 48),
        );
    final distance = sessionReadingDistance(session).displayValue;
    return TripSessionDisplay(
      session: session,
      id: session.id,
      status: statusLabel(session.status, loc),
      statusColor: statusColorFor(session.status, session.endReason),
      startLabel: startedAt == null ? '--' : formatTripListDateTime(startedAt),
      dateLabel: startedAt == null
          ? '--'
          : formatSessionEventDate(startedAt, loc),
      windowLabel: _formatTripWindow(startedAt, endedAt),
      durationLabel: formatDuration(duration),
      distanceLabel: distanceLabelFor(distance, loc),
      speedLabel: speedLabelFor(distance, duration, loc),
      socRange: socRangeLabel(
        session.startSoc.displayValue,
        session.endSoc.displayValue,
      ),
      socDelta: socDeltaLabel(
        session.startSoc.displayValue,
        session.endSoc.displayValue,
      ),
      odometerLabel: odometerLabelFor(
        session.endOdometer.displayValue ?? session.startOdometer.displayValue,
        loc,
      ),
      gearLabel: gearLabelFor(session.startGear, loc),
      endReason: session.endReason ?? fallbackEndReason(session.status, loc),
      updatedLabel: formatUpdated(session.updatedAtUtcMillis),
      startSoc: session.startSoc.displayValue,
      endSoc: session.endSoc.displayValue,
    );
  }

  final SessionRecord session;
  final String id;
  final String status;
  final Color statusColor;
  final String startLabel;
  final String dateLabel;
  final String windowLabel;
  final String durationLabel;
  final String distanceLabel;
  final String speedLabel;
  final String socRange;
  final String socDelta;
  final String odometerLabel;
  final String gearLabel;
  final String endReason;
  final String updatedLabel;
  final double? startSoc;
  final double? endSoc;

  bool get isActive => isLiveTripStatus(session.status);

  String get shortId {
    if (id.length <= 12) return id;
    return '${id.substring(0, 8)}...${id.substring(id.length - 4)}';
  }

  String get startSocLabel {
    return startSoc == null ? '--' : '${startSoc!.toStringAsFixed(1)}%';
  }

  String get endSocLabel {
    return endSoc == null ? '--' : '${endSoc!.toStringAsFixed(1)}%';
  }

  double get endSocFraction {
    final soc = (endSoc ?? startSoc ?? 0).clamp(0, 100);
    return soc / 100;
  }
}

String _formatTripWindow(DateTime? start, DateTime? end) {
  if (start == null) return '--:-- - --:--';
  final startLabel = '${twoDigits(start.hour)}:${twoDigits(start.minute)}';
  final endLabel = end == null
      ? '--:--'
      : '${twoDigits(end.hour)}:${twoDigits(end.minute)}';
  return '$startLabel - $endLabel';
}

bool isLiveTripStatus(String status) {
  final normalized = status.toUpperCase();
  return normalized == 'ARMED' ||
      normalized == 'ACTIVE' ||
      normalized == 'PENDING_END';
}
