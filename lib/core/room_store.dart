import 'package:telemetry_core/telemetry_core.dart';

/// The car's implementation of [TelemetryStore], querying the Android Room database over Pigeon.
///
/// Communicates over [TelemetryWireApi] to [TelemetryWireHandler] on Android.
class RoomStore implements TelemetryStore {
  RoomStore({TelemetryWireApi? wire}) : _wire = wire ?? TelemetryWireApi();

  final TelemetryWireApi _wire;

  @override
  Future<SessionListPage> listSessions({
    SessionFilter? filter,
    PageRequest? page,
  }) async {
    final filterWire = filter == null
        ? null
        : SessionFilterWire(
            kind: filter.kind?.name,
            fromUtcMillis: filter.fromUtcMillis,
            toUtcMillis: filter.toUtcMillis,
            status: filter.status,
          );
    final pageWire = page == null
        ? null
        : PageRequestWire(limit: page.limit, offset: page.offset);

    final pageResult = await _wire.storeListSessions(filterWire, pageWire);
    final sessions = [
      for (final s in pageResult.sessions) _parseSessionRecordWire(s),
    ];
    await _applyPlaces(sessions);

    return SessionListPage(
      sessions: sessions,
      totalCount: pageResult.totalCount,
      page: PageRequest(limit: pageResult.limit, offset: pageResult.offset),
      hasMore: pageResult.hasMore,
    );
  }

  /// Names the start place of every session the list will draw.
  ///
  /// A place is matched at read time and never stamped: renaming one
  /// renames the whole history at once. Same reduction [SqfliteStore] runs,
  /// from the same shared matcher.
  Future<void> _applyPlaces(List<SessionRecord> sessions) async {
    var withCoordinates = false;
    for (final session in sessions) {
      if (session.startLatitude != null && session.startLongitude != null) {
        withCoordinates = true;
        break;
      }
    }
    if (!withCoordinates) return;
    final placesResult = await _wire.getInsightPlaces();
    final places = [
      for (final p in placesResult.places)
        InsightPlace(
          id: p.id,
          name: p.name,
          latitude: p.latitude,
          longitude: p.longitude,
          radiusM: p.radiusM,
          autoName: p.autoName,
          autoNameUpdatedAtUtcMillis: p.autoNameUpdatedAtUtcMillis,
          autoNameSource: p.autoNameSource,
        ),
    ];
    for (var i = 0; i < sessions.length; i++) {
      final session = sessions[i];
      final place = placeNameAt(
        latitude: session.startLatitude,
        longitude: session.startLongitude,
        places: places,
      );
      if (place != null) {
        sessions[i] = session.copyWith(startPlace: place);
      }
    }
  }

  @override
  Future<SessionDetail?> session(String id) async {
    final detailWire = await _wire.storeGetSession(id);
    if (detailWire == null) return null;

    final sessionRecord = _parseSessionRecordWire(detailWire.session);
    final events = [
      for (final e in detailWire.events) _parseEventRecordWire(e),
    ];
    await _applyPlaces([sessionRecord]);
    return SessionDetail(
      session: sessionRecord,
      events: events,
      track: _parseTrackRowWire(detailWire.track),
    );
  }

  @override
  Future<TelemetrySeries> series(
    String id, {
    Set<String>? keys,
    int? widthMillis,
  }) async {
    final seriesWire = await _wire.storeGetSeries(
      id,
      keys?.toList(),
      widthMillis,
    );

    final intervals = [
      for (final inv in seriesWire.intervals) _parseIntervalRecordWire(inv),
    ];

    // A pending series positions by the monotonic pair (T7): the stamps are
    // boot-default until the TBox syncs the clock. Otherwise — trusted, or
    // rows from before the pair existed — the ordinal, exactly as today.
    final positionOf = intervalPositionOf(intervals);
    final reducedIntervals = widthMillis != null && widthMillis > 60000
        ? reduceIntervalRecordsByIndex(
            intervals,
            widthMillis: widthMillis,
            positionOf: positionOf,
          )
        : (List<IntervalRecord>.from(intervals)
            ..sort((a, b) => positionOf(a).compareTo(positionOf(b))));

    final sampleMap = <String, List<SamplePoint>>{};
    for (final series in seriesWire.sampleSeries) {
      sampleMap[series.key] = [
        for (final pt in series.points) _parseSamplePointWire(pt),
      ];
    }

    return TelemetrySeries(
      sessionId: id,
      intervals: reducedIntervals,
      samples: sampleMap,
    );
  }

  // --- Wire Parsers --------------------------------------------------------

  static Measurement _parseMeasurementWire(MeasurementWire wire) {
    final validity = switch (wire.validity.toLowerCase()) {
      'measured' => MeasurementValidity.measured,
      'estimated' => MeasurementValidity.estimated,
      'invalid' => MeasurementValidity.invalid,
      'unreported' => MeasurementValidity.unreported,
      _ =>
        wire.value != null
            ? MeasurementValidity.measured
            : MeasurementValidity.unreported,
    };
    return switch (validity) {
      MeasurementValidity.measured =>
        wire.value != null
            ? Measurement.measured(wire.value!, unit: wire.unit)
            : Measurement.unreported(unit: wire.unit, note: wire.note),
      MeasurementValidity.estimated =>
        wire.value != null
            ? Measurement.estimated(
                wire.value!,
                unit: wire.unit,
                note: wire.note,
              )
            : Measurement.unreported(unit: wire.unit, note: wire.note),
      MeasurementValidity.invalid => Measurement.invalid(
        unit: wire.unit,
        note: wire.note,
      ),
      MeasurementValidity.unreported => Measurement.unreported(
        unit: wire.unit,
        note: wire.note,
      ),
    };
  }

  static SessionRollup _parseSessionRollupWire(SessionRollupWire wire) {
    return SessionRollup(
      distance: _parseMeasurementWire(wire.distance),
      traction: _parseMeasurementWire(wire.traction),
      regen: _parseMeasurementWire(wire.regen),
      auxiliary: _parseMeasurementWire(wire.auxiliary),
      climate: _parseMeasurementWire(wire.climate),
      delivered: _parseMeasurementWire(wire.delivered),
      integratedSeconds: _parseMeasurementWire(wire.integratedSeconds),
    );
  }

  static SessionRecord _parseSessionRecordWire(SessionRecordWire wire) {
    final kind = SessionKind.fromName(wire.kind);
    return SessionRecord(
      id: wire.id,
      vehicleId: wire.vehicleId,
      kind: kind,
      status: wire.status,
      startedAtUtcMillis: wire.startedAtUtcMillis,
      startedAtElapsedNanos: wire.startedAtElapsedNanos,
      startedAtBootCount: wire.startedAtBootCount,
      endedAtUtcMillis: wire.endedAtUtcMillis,
      endedAtElapsedNanos: wire.endedAtElapsedNanos,
      endedAtBootCount: wire.endedAtBootCount,
      durationMillis: wire.durationMillis,
      rollup: _parseSessionRollupWire(wire.rollup),
      startOdometer: _parseMeasurementWire(wire.startOdometer),
      endOdometer: _parseMeasurementWire(wire.endOdometer),
      startSoc: _parseMeasurementWire(wire.startSoc),
      endSoc: _parseMeasurementWire(wire.endSoc),
      minSoc: _parseMeasurementWire(wire.minSoc),
      maxSoc: _parseMeasurementWire(wire.maxSoc),
      socAgreesWithIntegral: wire.socAgreesWithIntegral,
      startAmbientTemp: _parseMeasurementWire(wire.startAmbientTemp),
      endAmbientTemp: _parseMeasurementWire(wire.endAmbientTemp),
      meanAmbientTemp: _parseMeasurementWire(wire.meanAmbientTemp),
      plugType: wire.plugType,
      costPerKwh: wire.costPerKwh,
      paidAmount: wire.paidAmount,
      costCurrency: wire.costCurrency,
      chargeStartedAtUtcMillis: wire.chargeStartedAtUtcMillis,
      chargeEndedAtUtcMillis: wire.chargeEndedAtUtcMillis,
      plugDisconnectedAtUtcMillis: wire.plugDisconnectedAtUtcMillis,
      movementStartedAtUtcMillis: wire.movementStartedAtUtcMillis,
      chargeEndReason: wire.chargeEndReason,
      endReason: wire.endReason,
      startLatitude: wire.startLatitude,
      startLongitude: wire.startLongitude,
      startAltitudeM: wire.startAltitudeM,
      startGpsAccuracyM: wire.startGpsAccuracyM,
      startGear: wire.startGear,
      startPowerKw: wire.startPowerKw,
      movementStartedAtElapsedNanos: wire.movementStartedAtElapsedNanos,
      movementStartedAtBootCount: wire.movementStartedAtBootCount,
      chargeStartedAtElapsedNanos: wire.chargeStartedAtElapsedNanos,
      chargeStartedAtBootCount: wire.chargeStartedAtBootCount,
      chargeEndedAtElapsedNanos: wire.chargeEndedAtElapsedNanos,
      chargeEndedAtBootCount: wire.chargeEndedAtBootCount,
      plugDisconnectedAtElapsedNanos: wire.plugDisconnectedAtElapsedNanos,
      plugDisconnectedAtBootCount: wire.plugDisconnectedAtBootCount,
      noLongerReducible: wire.noLongerReducible,
      createdAtUtcMillis: wire.createdAtUtcMillis,
      updatedAtUtcMillis: wire.updatedAtUtcMillis,
      climbM: wire.climbM,
      descentM: wire.descentM,
      fixCount: wire.fixCount?.toInt(),
      sleepSeconds: wire.sleepSeconds?.toInt(),
      sleepSocDeltaPercent: wire.sleepSocDeltaPercent,
      sleepEnergyWhEstimate: wire.sleepEnergyWhEstimate,
    );
  }

  static TelemetryEventRecord _parseEventRecordWire(
    TelemetryEventRecordWire wire,
  ) {
    return TelemetryEventRecord(
      id: wire.id,
      sessionId: wire.sessionId,
      type: wire.type,
      occurredAtUtcMillis: wire.occurredAtUtcMillis,
      occurredAtElapsedNanos: wire.occurredAtElapsedNanos,
      signalKey: wire.signalKey,
      value: wire.value,
      previousValue: wire.previousValue,
      quality: wire.quality,
      source: wire.source,
      details: wire.details,
    );
  }

  static IntervalRecord _parseIntervalRecordWire(IntervalRecordWire wire) {
    return IntervalRecord(
      sessionId: wire.sessionId,
      startUtcMillis: wire.startUtcMillis,
      widthMillis: wire.widthMillis,
      traction: _parseMeasurementWire(wire.traction),
      regen: _parseMeasurementWire(wire.regen),
      auxiliary: _parseMeasurementWire(wire.auxiliary),
      climate: _parseMeasurementWire(wire.climate),
      delivered: _parseMeasurementWire(wire.delivered),
      distance: _parseMeasurementWire(wire.distance),
      coveredSeconds: wire.coveredSeconds,
      climateCoveredSeconds: wire.climateCoveredSeconds,
      speedCoveredSeconds: wire.speedCoveredSeconds,
      deliveredCoveredSeconds: wire.deliveredCoveredSeconds,
      startSoc: wire.startSoc != null
          ? _parseMeasurementWire(wire.startSoc!)
          : const Measurement.unreported(unit: '%'),
      endSoc: wire.endSoc != null
          ? _parseMeasurementWire(wire.endSoc!)
          : const Measurement.unreported(unit: '%'),
      startVoltage: wire.startVoltage != null
          ? _parseMeasurementWire(wire.startVoltage!)
          : const Measurement.unreported(unit: 'V'),
      endVoltage: wire.endVoltage != null
          ? _parseMeasurementWire(wire.endVoltage!)
          : const Measurement.unreported(unit: 'V'),
      // Time authority T7: the pair rides the wire, so the series reader can
      // place pending bars on the monotonic axis. Rows written before T2
      // carry nulls and fall back to the ordinal — most of the history.
      startElapsedNanos: wire.startElapsedNanos,
      startBootCount: wire.startBootCount,
      timeState: wire.timeState ?? 'unknown',
      correctedFromUtcMillis: null,
    );
  }

  static SamplePoint _parseSamplePointWire(SamplePointWire wire) {
    return SamplePoint(
      tUtcMillis: wire.tUtcMillis,
      tElapsedNanos: wire.tElapsedNanos,
      bootCount: wire.bootCount,
      value: _parseMeasurementWire(wire.value),
      groupId: wire.groupId,
    );
  }

  static TrackRow? _parseTrackRowWire(TrackRowWire? wire) {
    if (wire == null) return null;
    return trackRowFromWire(<String, Object?>{
      'encodingVersion': wire.encodingVersion,
      'pointCount': wire.pointCount,
      'path': wire.path,
      't': wire.t,
      'speed': wire.speed,
      'alt': wire.alt,
    });
  }
}
