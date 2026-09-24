import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  SessionRecord session({
    double? climbM,
    double? descentM,
    int? fixCount,
    double startAmbientTempC = 12,
    double endAmbientTempC = 18,
    double meanAmbientTempC = 15,
  }) => SessionRecord(
    id: 'trip-1',
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
    startAmbientTemp: Measurement.measured(startAmbientTempC, unit: '°C'),
    endAmbientTemp: Measurement.measured(endAmbientTempC, unit: '°C'),
    meanAmbientTemp: Measurement.measured(meanAmbientTempC, unit: '°C'),
    createdAtUtcMillis: 1000000,
    updatedAtUtcMillis: 1000000,
    climbM: climbM,
    descentM: descentM,
    fixCount: fixCount,
  );

  const emptySeries = TelemetrySeries(
    sessionId: 'trip-1',
    intervals: [],
    samples: {},
  );

  group('speed and altitude series', () {
    test('speedSeries reads from the Track when present, spikes included', () {
      final points = [
        const TrackPoint(
          latitude: -23.55,
          longitude: -46.63,
          tSeconds: 0,
          speedKmh: 10,
          altitudeM: 700,
        ),
        const TrackPoint(
          latitude: -23.551,
          longitude: -46.631,
          tSeconds: 5,
          speedKmh: 95,
          altitudeM: 705,
        ),
        const TrackPoint(
          latitude: -23.552,
          longitude: -46.632,
          tSeconds: 10,
          speedKmh: 12,
          altitudeM: 706,
        ),
      ];
      final reading = TripDetailReading(
        session: session(),
        series: emptySeries,
        track: TrackCodec.encode(points),
      );
      final series = reading.speedSeries;
      expect(series.map((p) => p.y), contains(closeTo(95, 0.2)));
    });

    test('speedSeries is empty when there is no Track', () {
      final reading = TripDetailReading(
        session: session(),
        series: emptySeries,
      );
      final series = reading.speedSeries;
      expect(series, isEmpty);
    });

    test('altitudeSeries reads from the Track when present', () {
      final points = [
        const TrackPoint(
          latitude: -23.55,
          longitude: -46.63,
          tSeconds: 0,
          speedKmh: 10,
          altitudeM: 111,
        ),
        const TrackPoint(
          latitude: -23.551,
          longitude: -46.631,
          tSeconds: 5,
          speedKmh: 10,
          altitudeM: 222,
        ),
      ];
      final reading = TripDetailReading(
        session: session(),
        series: emptySeries,
        track: TrackCodec.encode(points),
      );
      expect(reading.altitudeSeries.map((p) => p.y), [111, 222]);
    });

    test('a stop point surviving the Track shows on the speed chart', () {
      final points = [
        const TrackPoint(
          latitude: -23.55,
          longitude: -46.63,
          tSeconds: 0,
          speedKmh: 40,
          altitudeM: 700,
        ),
        // The stop: both ends held near zero and protected, so they survive
        // the once-run simplification already baked into the stored Track.
        const TrackPoint(
          latitude: -23.5505,
          longitude: -46.6305,
          tSeconds: 30,
          speedKmh: 0,
          altitudeM: 700,
          protected: true,
        ),
        const TrackPoint(
          latitude: -23.5505,
          longitude: -46.6305,
          tSeconds: 90,
          speedKmh: 0,
          altitudeM: 700,
          protected: true,
        ),
        const TrackPoint(
          latitude: -23.551,
          longitude: -46.631,
          tSeconds: 120,
          speedKmh: 45,
          altitudeM: 701,
        ),
      ];
      final reading = TripDetailReading(
        session: session(),
        series: emptySeries,
        track: TrackCodec.encode(points),
      );
      final series = reading.speedSeries;
      expect(series.map((p) => p.y), contains(0.0));
    });
  });

  group('climb and descent', () {
    test('altitudeGainM and altitudeLossM read the Session column', () {
      final reading = TripDetailReading(
        session: session(climbM: 123, descentM: 45),
        series: emptySeries,
      );
      expect(reading.altitudeGainM, 123);
      expect(reading.altitudeLossM, 45);
    });

    test(
      'altitudeGainM and altitudeLossM return null when Session column is null',
      () {
        final reading = TripDetailReading(
          session: session(),
          series: emptySeries,
        );
        expect(reading.altitudeGainM, isNull);
        expect(reading.altitudeLossM, isNull);
      },
    );
  });

  group('gps fix count', () {
    test('gpsPointCount prefers the Session column over the Track', () {
      final points = [
        const TrackPoint(
          latitude: -23.55,
          longitude: -46.63,
          tSeconds: 0,
          speedKmh: 10,
          altitudeM: 700,
        ),
      ];
      final reading = TripDetailReading(
        session: session(fixCount: 520),
        series: emptySeries,
        track: TrackCodec.encode(points),
      );
      expect(reading.gpsPointCount, 520);
    });
  });

  group('temperature', () {
    test('the temperature tile always answers from the Session', () {
      final reading = TripDetailReading(
        session: session(
          startAmbientTempC: 5,
          endAmbientTempC: 9,
          meanAmbientTempC: 7,
        ),
        series: emptySeries,
      );
      expect(reading.session.startAmbientTemp.displayValue, 5);
      expect(reading.session.endAmbientTemp.displayValue, 9);
      expect(reading.meanAmbientTempC, 7);
    });
  });
}
