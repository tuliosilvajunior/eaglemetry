import 'package:capy_companion/sync/sqflite_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/memory_archive.dart';

void main() {
  test('a synced position group draws a route on the phone', () async {
    final archive = await memoryArchive();
    await archive.upsertTrip({
      'id': 'trip-1',
      'kind': 'TRIP',
      'status': 'CLOSED',
      'startedAtUtcMillis': 1000,
      'startedAtElapsedNanos': 1000 * 1000000,
      'endedAtUtcMillis': 4000,
    });
    // Route now comes from Track, not Sample position group (issue 184).
    final track = TrackCodec.encode(const [
      TrackPoint(
        latitude: -23.5,
        longitude: -46.6,
        tSeconds: 0,
        speedKmh: 30,
        altitudeM: 700,
      ),
      TrackPoint(
        latitude: -23.51,
        longitude: -46.61,
        tSeconds: 1,
        speedKmh: 32,
        altitudeM: 701,
      ),
    ]);
    await archive.upsertTrack({
      'sessionId': 'trip-1',
      'encodingVersion': track.encodingVersion,
      'pointCount': track.pointCount,
      'path': track.path,
      't': track.t,
      'speed': track.speed,
      'alt': track.alt,
    });

    final store = SqfliteStore(archive.database);
    final detail = await store.session('trip-1');
    final series = await store.series('trip-1');
    final reading = TripDetailReading(
      session: detail!.session,
      series: series,
      events: detail.events,
      track: detail.track,
    );

    expect(reading.routePoints(expanded: true), hasLength(2));
    expect(
      reading.routePoints(expanded: true).first.latitude,
      closeTo(-23.5, 0.0001),
    );
  });
}
