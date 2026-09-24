/// The recorded window, reduced from the session list.
///
/// It replaces the car-side history summary. Nothing here is measured: the
/// timeline is the sessions laid on a clock, and every total is a sum of what
/// the car already folded (Rule 2.1).
library;

import 'dto/telemetry_dto.dart';
import 'dto/telemetry_store_models.dart';
import 'session_reading.dart';

const int _dayMillis = 24 * 60 * 60 * 1000;

/// How far back a named range reaches from [now].
DateTime historyRangeStart(String range, DateTime now) => switch (range) {
  '24h' => now.subtract(const Duration(days: 1)),
  '30d' => now.subtract(const Duration(days: 30)),
  _ => now.subtract(const Duration(days: 7)),
};

/// The totals of one window.
///
/// Every field is a sum or a ratio of sums over what the car folded. There is
/// no second integral here, and there is no SOC energy: a drive's energy is
/// the stored integral and nothing else.
class HistoryWindowMetrics {
  const HistoryWindowMetrics({
    required this.tripCount,
    required this.chargeCount,
    required this.sessionCount,
    required this.totalTripDistanceKm,
    required this.tripNetEnergyKwh,
    required this.regenRecoveredKwh,
    required this.chargedEnergyKwh,
    required this.socDeltaPercent,
  });

  final int tripCount;
  final int chargeCount;
  final int sessionCount;
  final double? totalTripDistanceKm;
  final double? tripNetEnergyKwh;
  final double? regenRecoveredKwh;
  final double? chargedEnergyKwh;
  final double? socDeltaPercent;

  /// Total energy over total distance, never the mean of the per-trip ratios.
  double? get averageEfficiencyWhPerKm {
    final km = totalTripDistanceKm;
    final kwh = tripNetEnergyKwh;
    if (km == null || kwh == null || km <= 0) return null;
    return kwh * 1000 / km;
  }

  double? get averageEfficiencyKmPerKwh {
    final km = totalTripDistanceKm;
    final kwh = tripNetEnergyKwh;
    if (km == null || kwh == null || kwh <= 0) return null;
    return km / kwh;
  }
}

/// One window of recorded history, reduced.
class HistorySummaryReading {
  const HistorySummaryReading({
    required this.range,
    required this.startUtcMillis,
    required this.endUtcMillis,
    required this.metrics,
    required this.timelineDays,
    required this.sessions,
  });

  /// Reduces [records] — every session the window holds, any kind.
  factory HistorySummaryReading.fromSessions({
    required String range,
    required DateTime start,
    required DateTime end,
    required List<SessionRecord> records,
    required List<String> weekdayLabels,
  }) {
    final rows = <HistorySessionRow>[];
    for (final record in records) {
      rows.add(_rowOf(record));
    }
    rows.sort((a, b) => b.startUtcMillis.compareTo(a.startUtcMillis));

    final days = <HistoryTimelineDay>[];
    var cursor = DateTime(start.year, start.month, start.day);
    while (!cursor.isAfter(end)) {
      final dayStart = cursor.millisecondsSinceEpoch;
      final dayEnd = dayStart + _dayMillis;
      final blocks = <HistoryTimelineBlock>[];
      for (final record in records) {
        final block = _blockOf(record, dayStart, dayEnd);
        if (block != null) blocks.add(block);
      }
      blocks.sort((a, b) => a.startFraction.compareTo(b.startFraction));
      days.add(
        HistoryTimelineDay(
          dayStartUtcMillis: dayStart,
          // Sunday is 7 in Dart and 1 in the label list, so the index wraps.
          label: weekdayLabels[cursor.weekday % 7],
          blocks: blocks,
        ),
      );
      cursor = cursor.add(const Duration(days: 1));
    }

    return HistorySummaryReading(
      range: range,
      startUtcMillis: start.millisecondsSinceEpoch,
      endUtcMillis: end.millisecondsSinceEpoch,
      metrics: _metricsOf(records),
      timelineDays: days,
      sessions: rows,
    );
  }

  final String range;
  final int startUtcMillis;
  final int endUtcMillis;
  final HistoryWindowMetrics metrics;
  final List<HistoryTimelineDay> timelineDays;
  final List<HistorySessionRow> sessions;

  static HistoryWindowMetrics _metricsOf(List<SessionRecord> records) {
    var trips = 0;
    var charges = 0;
    double? distance;
    double? net;
    double? regen;
    double? charged;
    double? socDelta;
    for (final record in records) {
      switch (record.kind) {
        case SessionKind.continuous:
          break;
        case SessionKind.trip:
          trips += 1;
          distance = _add(
            distance,
            sessionReadingDistance(record).displayValue,
          );
          net = _add(net, sessionReadingNetKwh(record).displayValue);
          regen = _add(
            regen,
            record.rollup.regen
                .map((wh) => wh / 1000, unit: 'kWh')
                .displayValue,
          );
        case SessionKind.charge:
          charges += 1;
          charged = _add(
            charged,
            sessionReadingDeliveredKwh(record).displayValue,
          );
        case SessionKind.parked:
          break;
      }
      socDelta = _add(socDelta, sessionReadingSocDelta(record));
    }
    return HistoryWindowMetrics(
      tripCount: trips,
      chargeCount: charges,
      sessionCount: records.length,
      totalTripDistanceKm: distance,
      tripNetEnergyKwh: net,
      regenRecoveredKwh: regen,
      chargedEnergyKwh: charged,
      // The sum of the per-session deltas, which is the pack's whole journey
      // over the window and not the difference of its two ends.
      socDeltaPercent: socDelta == null ? null : -socDelta,
    );
  }

  /// Null plus a value is that value. Null plus nothing stays null, because a
  /// window nobody measured is not a window that measured zero.
  static double? _add(double? total, double? value) {
    if (value == null || !value.isFinite) return total;
    return (total ?? 0) + value;
  }

  static HistorySessionRow _rowOf(SessionRecord record) {
    final isCharge = record.kind == SessionKind.charge;
    final energy = isCharge
        ? sessionReadingDeliveredKwh(record).displayValue
        : sessionReadingNetKwh(record).displayValue;
    final distance = sessionReadingDistance(record).displayValue;
    final duration = sessionReadingDurationMillis(record) ?? 0;
    final startSoc = record.startSoc.displayValue;
    final endSoc = record.endSoc.displayValue;
    return HistorySessionRow(
      id: record.id,
      type: record.kind.name.toUpperCase(),
      status: record.status,
      startUtcMillis: record.startedAtUtcMillis,
      endUtcMillis: _endOf(record),
      durationMillis: duration,
      socStart: startSoc,
      socEnd: endSoc,
      socDeltaPercent: startSoc == null || endSoc == null
          ? null
          : endSoc - startSoc,
      distanceKm: isCharge ? null : distance,
      energyKwh: energy,
      efficiencyWhPerKm:
          isCharge || distance == null || energy == null || distance <= 0
          ? null
          : energy * 1000 / distance,
      reason: record.endReason ?? record.chargeEndReason,
    );
  }

  static int _endOf(SessionRecord record) => record.kind == SessionKind.charge
      ? record.plugDisconnectedAtUtcMillis ??
            record.chargeEndedAtUtcMillis ??
            record.endedAtUtcMillis ??
            record.updatedAtUtcMillis
      : record.endedAtUtcMillis ?? record.updatedAtUtcMillis;

  static HistoryTimelineBlock? _blockOf(
    SessionRecord record,
    int dayStart,
    int dayEnd,
  ) {
    final start = record.startedAtUtcMillis;
    final end = _endOf(record);
    if (end <= dayStart || start >= dayEnd) return null;
    final clippedStart = start < dayStart ? dayStart : start;
    var clippedEnd = end > dayEnd ? dayEnd : end;
    if (clippedEnd < clippedStart + 1) clippedEnd = clippedStart + 1;
    return HistoryTimelineBlock(
      type: record.kind.name.toUpperCase(),
      sessionId: record.id,
      startFraction: ((clippedStart - dayStart) / _dayMillis).clamp(0.0, 1.0),
      endFraction: ((clippedEnd - dayStart) / _dayMillis).clamp(0.0, 1.0),
      startUtcMillis: clippedStart,
      endUtcMillis: clippedEnd,
    );
  }
}
