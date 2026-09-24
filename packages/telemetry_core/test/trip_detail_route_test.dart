import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  final trackPoints = [
    const TrackPoint(
      latitude: -23.5505,
      longitude: -46.6333,
      tSeconds: 0,
      speedKmh: 40,
      altitudeM: 760,
    ),
    const TrackPoint(
      latitude: -23.5510,
      longitude: -46.6340,
      tSeconds: 10,
      speedKmh: 50,
      altitudeM: 765,
    ),
    const TrackPoint(
      latitude: -23.5520,
      longitude: -46.6350,
      tSeconds: 20,
      speedKmh: 60,
      altitudeM: 770,
    ),
  ];
  final encoded = TrackCodec.encode(trackPoints);

  SessionRecord session({String id = 'trip-1'}) => SessionRecord(
    id: id,
    vehicleId: 'v1',
    kind: SessionKind.trip,
    status: 'CLOSED',
    startedAtUtcMillis: 1000000,
    startedAtElapsedNanos: 0,
    durationMillis: 20000,
    rollup: const SessionRollup(
      distance: Measurement.measured(5, unit: 'km'),
      traction: Measurement.measured(800, unit: 'Wh'),
      regen: Measurement.measured(100, unit: 'Wh'),
      auxiliary: Measurement.measured(50, unit: 'Wh'),
      climate: Measurement.measured(30, unit: 'Wh'),
      delivered: Measurement.unreported(unit: 'Wh'),
      integratedSeconds: Measurement.measured(1200, unit: 's'),
    ),
    startOdometer: const Measurement.measured(10000, unit: 'km'),
    endOdometer: const Measurement.measured(10005, unit: 'km'),
    startSoc: const Measurement.measured(80, unit: '%'),
    endSoc: const Measurement.measured(75, unit: '%'),
    minSoc: const Measurement.measured(75, unit: '%'),
    maxSoc: const Measurement.measured(80, unit: '%'),
    startAmbientTemp: const Measurement.unreported(unit: '°C'),
    endAmbientTemp: const Measurement.unreported(unit: '°C'),
    meanAmbientTemp: const Measurement.unreported(unit: '°C'),
    createdAtUtcMillis: 1000000,
    updatedAtUtcMillis: 1000000,
  );

  group('route source', () {
    test('a session with a Track reads the route from it', () {
      final reading = TripDetailReading(
        session: session(),
        series: const TelemetrySeries(
          sessionId: 'trip-1',
          intervals: [],
          samples: {},
        ),
        track: encoded,
      );
      final route = reading.routePoints(expanded: true);
      expect(route, hasLength(3));
      expect(route[0].latitude, closeTo(-23.5505, 1e-4));
      expect(route[0].longitude, closeTo(-46.6333, 1e-4));
      expect(route[2].speedKmh, closeTo(60, 0.2));
      expect(route[1].altitudeM, closeTo(765, 0.2));
    });

    test('a session without a Track returns empty route', () {
      final reading = TripDetailReading(
        session: session(),
        series: const TelemetrySeries(
          sessionId: 'trip-1',
          intervals: [],
          samples: {},
        ),
      );
      final route = reading.routePoints(expanded: true);
      expect(route, isEmpty);
    });

    test('gpsPointCount reads the Track when present', () {
      final reading = TripDetailReading(
        session: session(),
        series: const TelemetrySeries(
          sessionId: 'trip-1',
          intervals: [],
          samples: {},
        ),
        track: encoded,
      );
      expect(reading.gpsPointCount, 3);
    });

    test('colour-by-speed survives the Track path', () {
      final reading = TripDetailReading(
        session: session(),
        series: const TelemetrySeries(
          sessionId: 'trip-1',
          intervals: [],
          samples: {},
        ),
        track: encoded,
      );
      final route = reading.routePoints(expanded: true);
      for (final point in route) {
        expect(point.speedKmh, isNotNull);
      }
    });

    test('an empty Track returns empty route', () {
      final emptyTrack = TrackCodec.encode(const []);
      final reading = TripDetailReading(
        session: session(),
        series: const TelemetrySeries(
          sessionId: 'trip-1',
          intervals: [],
          samples: {},
        ),
        track: emptyTrack,
      );
      final route = reading.routePoints(expanded: true);
      expect(route, isEmpty);
    });

    test('decimation limits apply to the Track route', () {
      final manyPoints = List.generate(
        2000,
        (i) => TrackPoint(
          latitude: -23.5505 + i * 0.0001,
          longitude: -46.6333 + i * 0.0001,
          tSeconds: i.toDouble(),
          speedKmh: 50,
          altitudeM: 760,
        ),
      );
      final big = TrackCodec.encode(manyPoints);
      final reading = TripDetailReading(
        session: session(),
        series: const TelemetrySeries(
          sessionId: 'trip-1',
          intervals: [],
          samples: {},
        ),
        track: big,
      );
      final preview = reading.routePoints(expanded: false);
      final expanded = reading.routePoints(expanded: true);
      expect(preview.length, lessThanOrEqualTo(kRoutePreviewPointLimit));
      expect(expanded.length, lessThanOrEqualTo(kRouteExpandedPointLimit));
      expect(reading.gpsPointCount, 2000);
    });
  });
}
