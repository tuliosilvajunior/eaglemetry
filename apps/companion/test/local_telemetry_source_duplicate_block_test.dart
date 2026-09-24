import 'package:capy_companion/sync/local_telemetry_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/memory_archive.dart';

void main() {
  group('LocalTelemetrySource near-duplicate block', () {
    test('second place with one normalized name within 500 m is refused and '
        'nothing persists', () async {
      final archive = await memoryArchive();
      final source = LocalTelemetrySource(archive);
      await source.saveInsightPlace(
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
      );

      await expectLater(
        source.saveInsightPlace(
          name: '  casa ',
          latitude: -10.181,
          longitude: -48.33,
        ),
        throwsA(
          isA<DuplicatePlaceException>().having(
            (e) => e.toString(),
            'message',
            "Ja existe 'Casa' a 111 m — use raio maior ou mescle",
          ),
        ),
      );

      final places = await source.insightPlaces();
      expect(places.places, hasLength(1));
    });

    test('same name beyond 500 m saves', () async {
      final archive = await memoryArchive();
      final source = LocalTelemetrySource(archive);
      await source.saveInsightPlace(
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
      );
      final second = await source.saveInsightPlace(
        name: 'CASA',
        latitude: -10.19,
        longitude: -48.33,
      );
      expect((await source.insightPlaces()).places, hasLength(2));
      expect(second.name, 'CASA');
    });

    test('different name nearby saves', () async {
      final archive = await memoryArchive();
      final source = LocalTelemetrySource(archive);
      await source.saveInsightPlace(
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
      );
      await source.saveInsightPlace(
        name: 'Trabalho',
        latitude: -10.1805,
        longitude: -48.3302,
      );
      expect((await source.insightPlaces()).places, hasLength(2));
    });

    test('updating the row by its own id stays allowed', () async {
      final archive = await memoryArchive();
      final source = LocalTelemetrySource(archive);
      final first = await source.saveInsightPlace(
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
      );
      final updated = await source.saveInsightPlace(
        id: first.id,
        name: 'Casa',
        latitude: -10.182,
        longitude: -48.331,
        radiusM: 400,
      );
      final places = await source.insightPlaces();
      expect(places.places, hasLength(1));
      expect(places.places.single.radiusM, 400);
      expect(updated.radiusM, 400);
    });

    test('tombstoned rows no longer block a new place at their spot', () async {
      final archive = await memoryArchive();
      final source = LocalTelemetrySource(archive);
      final first = await source.saveInsightPlace(
        name: 'Casa',
        latitude: -10.18,
        longitude: -48.33,
      );
      await source.deleteInsightPlace(first.id);

      final recreated = await source.saveInsightPlace(
        name: 'casa',
        latitude: -10.18,
        longitude: -48.33,
      );
      expect((await source.insightPlaces()).places, hasLength(1));
      expect(recreated.id, isNot(first.id));
      // Tombstone row survives for sync.
      expect(await archive.database.allPlaces(), hasLength(2));
    });
  });

  group('LocalTelemetrySource merge propagation', () {
    test('tombstone push and keeper update both reach the outbox, one live row '
        'stays and candidates re-derive', () async {
      final archive = await memoryArchive();
      final source = LocalTelemetrySource(archive);
      // Two duplicates from before the blocker existed, seeded directly.
      await archive.upsertPlace({
        'id': 'older',
        'name': 'Casa',
        'latitude': -10.18,
        'longitude': -48.33,
        'radiusM': 100.0,
        'createdAtUtcMillis': 1000,
        'updatedAtUtcMillis': 1000,
        'origin': kAnnotationOriginCar,
        'deletedAtUtcMillis': null,
      });
      await archive.upsertPlace({
        'id': 'newer',
        'name': 'casa ',
        'latitude': -10.1818,
        'longitude': -48.33,
        'radiusM': 100.0,
        'createdAtUtcMillis': 2000,
        'updatedAtUtcMillis': 2000,
        'origin': kAnnotationOriginCar,
        'deletedAtUtcMillis': null,
      });

      var data = buildPlacesData(
        places: (await source.insightPlaces()).places,
        trips: const [],
      );
      expect(data.duplicatePairs, hasLength(1));

      // The merge flow: tombstone the loser first, then update the keeper
      // with the proposed geometry.
      await source.deleteInsightPlace('newer');
      await source.saveInsightPlace(
        id: 'older',
        name: 'Casa',
        latitude: -10.1809,
        longitude: -48.33,
        radiusM: proposeMergeRadiusM(
          InsightPlace(
            id: 'older',
            name: 'Casa',
            latitude: -10.18,
            longitude: -48.33,
            radiusM: 100,
          ),
          InsightPlace(
            id: 'newer',
            name: 'casa ',
            latitude: -10.1818,
            longitude: -48.33,
            radiusM: 100,
          ),
        ),
      );

      final places = await source.insightPlaces();
      expect(places.places, hasLength(1));
      expect(places.places.single.id, 'older');
      expect(places.places.single.latitude, closeTo(-10.1809, 1e-9));

      // Both writes wait in the outbox for the car.
      final pushes = await archive.database.pendingAnnotationPush();
      final placePushes = pushes
          .where((p) => p.stream == SyncStreamType.places.name)
          .toList();
      expect(placePushes, hasLength(2));
      expect(placePushes[0].row['id'], 'newer');
      expect(placePushes[0].row['deletedAtUtcMillis'], isNotNull);
      expect(placePushes[1].row['id'], 'older');
      expect(placePushes[1].row['latitude'], closeTo(-10.1809, 1e-9));

      // The tombstone row itself survives with its stamp.
      final rows = await archive.database.allPlaces();
      final tombstone = rows.where((r) => r['id'] == 'newer').single;
      expect(tombstone['deletedAtUtcMillis'], isNotNull);

      // After sync would land, the list derives no more warnings and the
      // candidate derivation sees one circle only.
      data = buildPlacesData(places: places.places, trips: const []);
      expect(data.duplicatePairs, isEmpty);
    });
  });
}
