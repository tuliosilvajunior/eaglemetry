import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../../core/efficiency_unit.dart';
import '../../core/telemetry_api.dart';
import '../../core/telemetry_format.dart';
import '../../l10n/app_localizations.dart';
import '../../screens/charging/charging_session_display.dart'
    show chargePlugLabel;
import 'package:capy_ui/capy_ui.dart';
import 'history_format.dart';

/// The open session, with whatever is drawn beside it.
@immutable
sealed class HistoryDetailPage {
  const HistoryDetailPage();

  /// Which session this page is about.
  ///
  /// Not for reading — for telling one page from another. A refresh rebuilds
  /// the page object without the reader having gone anywhere, so anything the
  /// reader has opened on this session survives it, and only a different id
  /// clears it.
  String get sessionId;

  /// The session's own heading — when it happened.
  String title(BuildContext context);

  /// The rows the facts panel prints, in reading order.
  List<HistoryFact> facts(AppLocalizations loc);

  /// Where the session happened, or empty when it recorded no position.
  ///
  /// [expanded] asks for the denser series: the car stores a decimated preview
  /// for a small card and a fuller route for a large one, and a route drawn at
  /// preview resolution across half the screen shows its own corners cut.
  List<RouteMapPoint> routePoints({required bool expanded});
}

class HistoryTripDetailPage extends HistoryDetailPage {
  const HistoryTripDetailPage({
    required this.reading,
    required this.buckets,
    required this.insightSelection,
    required this.insightTrips,
    required this.places,
    this.routeIndex,
  });

  final TripDetailReading reading;

  SessionRecord get session => reading.session;
  final List<EnergyBucket> buckets;
  final InsightSelection insightSelection;
  final List<InsightTrip> insightTrips;
  final List<InsightPlace> places;
  final InsightRouteIndex? routeIndex;

  InsightTrip? get insightSubject {
    for (final trip in insightTrips) {
      if (trip.id == session.id) return trip;
    }
    return null;
  }

  InsightRouteMatch? get routeMatch {
    final subject = insightSubject;
    if (subject == null) return null;
    if (routeIndex != null) {
      return routeIndex!.matchOf(subject.id);
    }
    return matchInsightTripRoute(
      subject: subject,
      corpus: insightTrips,
      places: places,
    );
  }

  @override
  String get sessionId => session.id;

  @override
  String title(BuildContext context) {
    final started = dateTimeFromMillis(session.startedAtUtcMillis);
    return started == null ? '--' : formatTripListDateTime(started);
  }

  @override
  List<HistoryFact> facts(AppLocalizations loc) {
    final duration = reading.durationMillis;
    return [
      HistoryFact(loc.v2HistoryStart, historyClock(session.startedAtUtcMillis)),
      HistoryFact(loc.v2HistoryEnd, historyClock(session.endedAtUtcMillis)),
      HistoryFact(
        loc.v2HistoryDuration,
        formatDuration(
          duration == null ? null : Duration(milliseconds: duration),
        ),
      ),
      HistoryFact(
        loc.v2HistoryDistance,
        distanceLabelFor(reading.distanceKm, loc),
      ),
      HistoryFact(
        loc.v2HistorySoc,
        socRangeLabel(
          session.startSoc.displayValue,
          session.endSoc.displayValue,
        ),
      ),
      HistoryFact(
        loc.v2HistoryTemperature,
        ambientTempRangeLabel(
          session.startAmbientTemp.displayValue,
          session.endAmbientTemp.displayValue,
        ),
      ),
      HistoryFact(
        loc.v2HistoryAltitude,
        altitudeGainLabel(reading.altitudeGainM),
      ),
      HistoryFact(loc.v2HistoryConsumed, energyLabel(reading.netEnergyKwh)),
      HistoryFact(loc.v2HistoryRegen, energyLabel(reading.regeneratedKwh)),
      HistoryFact(
        loc.v2HistoryEfficiency,
        formatEfficiencyWhPerKmForUnit(
          reading.efficiencyWhPerKm,
          EfficiencyUnitController.instance.unit,
        ),
      ),
    ];
  }

  @override
  List<RouteMapPoint> routePoints({required bool expanded}) {
    final points = reading.routePoints(expanded: expanded);
    return [
      for (final point in points)
        RouteMapPoint(
          latitude: point.latitude,
          longitude: point.longitude,
          speedKmh: point.speedKmh,
        ),
    ];
  }
}

class HistoryChargeDetailPage extends HistoryDetailPage {
  const HistoryChargeDetailPage({required this.reading});

  final ChargeDetailReading reading;

  SessionRecord get session => reading.session;

  @override
  String get sessionId => session.id;

  /// When the plotted window opens. The chart's columns are offsets from it,
  /// so a tooltip that names a clock time has to start here.
  DateTime? get windowStart {
    final start =
        session.chargeStartedAtUtcMillis ?? session.startedAtUtcMillis;
    return dateTimeFromMillis(start);
  }

  /// The whole plug-in, charge and idle alike — the same window the charging
  /// screen plots, so one session does not look like two different sessions on
  /// two screens. Bounded by the session-duration plausibility ceiling: a
  /// stamp pair the clock lied about plots nothing rather than 22000 hours of
  /// empty columns.
  Duration? get window {
    final start =
        session.chargeStartedAtUtcMillis ?? session.startedAtUtcMillis;
    final end =
        session.plugDisconnectedAtUtcMillis ?? session.chargeEndedAtUtcMillis;
    if (end == null || end <= start) return null;
    final span = end - start;
    if (span > kMaxChargeWallDurationMillis) return null;
    return Duration(milliseconds: span);
  }

  @override
  String title(BuildContext context) {
    final plugged = dateTimeFromMillis(session.startedAtUtcMillis);
    return plugged == null ? '--' : formatTripListDateTime(plugged);
  }

  @override
  List<HistoryFact> facts(AppLocalizations loc) {
    return [
      HistoryFact(loc.v2HistoryStart, historyClock(session.startedAtUtcMillis)),
      HistoryFact(
        loc.v2HistoryEnd,
        historyClock(
          session.plugDisconnectedAtUtcMillis ?? session.chargeEndedAtUtcMillis,
        ),
      ),
      HistoryFact(
        loc.v2HistoryDuration,
        formatDuration(
          reading.durationMillis == null
              ? null
              : Duration(milliseconds: reading.durationMillis!),
        ),
      ),
      HistoryFact(
        loc.v2HistorySoc,
        socRangeLabel(
          session.startSoc.displayValue,
          session.endSoc.displayValue,
        ),
      ),
      HistoryFact(
        loc.v2HistoryTemperature,
        ambientTempRangeLabel(
          session.startAmbientTemp.displayValue,
          session.endAmbientTemp.displayValue,
        ),
      ),
      HistoryFact(
        loc.v2HistoryEnergyAdded,
        energyLabel(reading.estimatedEnergyKwh),
      ),
      HistoryFact(
        loc.v2HistoryAvgPower,
        liveNumber(reading.averagePowerKw, loc.unitKw, decimals: 1),
      ),
      HistoryFact(
        loc.v2HistoryPeakPower,
        liveNumber(reading.peakPowerKw, loc.unitKw, decimals: 1),
      ),
      HistoryFact(loc.v2HistoryPlug, chargePlugLabel(session.plugType, loc)),
    ];
  }

  /// One position: where the car was plugged in. A charge does not move, so
  /// there is no route to draw and no denser version to ask for.
  @override
  List<RouteMapPoint> routePoints({required bool expanded}) {
    final latitude = session.startLatitude;
    final longitude = session.startLongitude;
    if (latitude == null || longitude == null) return const [];
    return [RouteMapPoint(latitude: latitude, longitude: longitude)];
  }
}

/// One battery, and the sessions it was spent on.
///
/// The row in the list already carries every number this cycle has, so this
/// page adds none. It answers the other question: what the battery was spent
/// *on*, in the order it happened.
class HistoryCycleDetailPage extends HistoryDetailPage {
  const HistoryCycleDetailPage({required this.cycle, required this.sessions});

  final BatteryCycleSummary cycle;
  final BatteryCycleSessionsResult sessions;

  /// A cycle has no id, it has an ordinal. It is the identity all the same.
  @override
  String get sessionId => 'cycle-${cycle.ordinal}';

  @override
  String title(BuildContext context) {
    final start = dateTimeFromMillis(cycle.startUtcMillis);
    final end = dateTimeFromMillis(cycle.endUtcMillis);
    if (start == null || end == null) return '--';
    return '${formatTripListDateTime(start)} — ${formatTripListDateTime(end)}';
  }

  @override
  List<HistoryFact> facts(AppLocalizations loc) {
    return [
      HistoryFact(loc.v2CycleTimelineSessions, '${sessions.sessions.length}'),
      HistoryFact(loc.v2CycleDistance, distanceLabelFor(cycle.distanceKm, loc)),
      HistoryFact(
        loc.v2CycleEnergy,
        cycle.hasEnergy ? energyLabel(cycle.tripEnergyKwh) : '--',
      ),
      HistoryFact(loc.v2HistoryDuration, _cycleSpan(cycle)),
    ];
  }

  /// A cycle has no route of its own. It is months of driving, and a line
  /// through every one of them would say nothing about the battery.
  @override
  List<RouteMapPoint> routePoints({required bool expanded}) => const [];
}

String _cycleSpan(BatteryCycleSummary cycle) {
  final span = cycle.endUtcMillis - cycle.startUtcMillis;
  if (span <= 0) return '--';
  return formatDuration(Duration(milliseconds: span));
}

/// One labelled reading in the facts panel.
@immutable
class HistoryFact {
  const HistoryFact(this.label, this.value);

  final String label;

  /// Pre-formatted, and already `--` where the car reported nothing.
  final String value;
}
