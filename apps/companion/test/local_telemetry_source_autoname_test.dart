import 'package:capy_companion/sync/local_telemetry_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/memory_archive.dart';

void main() {
  group('LocalTelemetrySource autoName', () {
    test(
      'saveInsightPlace persists autoName and reading returns name ?? autoName',
      () async {
        final archive = await memoryArchive();
        final source = LocalTelemetrySource(archive);

        final saved = await source.saveInsightPlace(
          name: 'Home',
          latitude: -23.55,
          longitude: -46.63,
          autoName: 'Rua Auto',
          autoNameUpdatedAtUtcMillis: 123456,
          autoNameSource: 'nominatim',
        );

        expect(saved.name, 'Home');
        expect(saved.autoName, 'Rua Auto');
        expect(saved.autoNameUpdatedAtUtcMillis, 123456);
        expect(saved.autoNameSource, 'nominatim');
        expect(saved.displayName, 'Home');

        final places = await source.insightPlaces();
        expect(places.places, hasLength(1));
        expect(places.places.single.displayName, 'Home');
        expect(places.places.single.autoName, 'Rua Auto');
      },
    );

    test('displayName fallback when name empty uses autoName', () async {
      final archive = await memoryArchive();
      final source = LocalTelemetrySource(archive);

      // Save with empty name but autoName (simulating clearing user name)
      // Use direct archive upsert to allow empty name, then read via source.
      final now = DateTime.now().millisecondsSinceEpoch;
      await archive.upsertPlace({
        'id': 'p1',
        'name': '',
        'latitude': -23.55,
        'longitude': -46.63,
        'radiusM': 150,
        'autoName': 'Avenida Fallback',
        'autoNameUpdatedAtUtcMillis': now,
        'autoNameSource': 'nominatim',
        'createdAtUtcMillis': now,
        'updatedAtUtcMillis': now,
        'origin': kAnnotationOriginPhone,
        'deletedAtUtcMillis': null,
      });

      final places = await source.insightPlaces();
      expect(places.places, hasLength(1));
      expect(places.places.single.name, '');
      expect(places.places.single.autoName, 'Avenida Fallback');
      expect(places.places.single.displayName, 'Avenida Fallback');

      // Also verify placeNameAt fallback
      final nameAt = placeNameAt(
        latitude: -23.55,
        longitude: -46.63,
        places: places.places,
      );
      expect(nameAt, 'Avenida Fallback');
    });

    test('name precedence over autoName when both present', () async {
      final archive = await memoryArchive();
      final source = LocalTelemetrySource(archive);

      await source.saveInsightPlace(
        name: 'Meu Lar',
        latitude: 0,
        longitude: 0,
        autoName: 'Sugestao',
      );

      final places = await source.insightPlaces();
      expect(places.places.single.displayName, 'Meu Lar');
      // update with different autoName, name still wins
      final id = places.places.single.id;
      await source.saveInsightPlace(
        id: id,
        name: 'Meu Lar',
        latitude: 0,
        longitude: 0,
        autoName: 'Outra Sugestao',
      );
      final after = await source.insightPlaces();
      expect(after.places.single.displayName, 'Meu Lar');
      expect(after.places.single.autoName, 'Outra Sugestao');
    });

    test('tombstone hides place even with autoName', () async {
      final archive = await memoryArchive();
      final source = LocalTelemetrySource(archive);

      final saved = await source.saveInsightPlace(
        name: 'Home',
        latitude: 0,
        longitude: 0,
        autoName: 'Auto',
      );
      expect((await source.insightPlaces()).places, hasLength(1));

      await source.deleteInsightPlace(saved.id);

      final afterDelete = await source.insightPlaces();
      expect(afterDelete.places, isEmpty);

      // Row still exists with tombstone
      final all = await archive.database.allPlaces();
      expect(all, hasLength(1));
      expect(all.single['deletedAtUtcMillis'], isNotNull);
      expect(all.single['autoName'], 'Auto');
    });

    test('LWW keeps car > phone for places with autoName', () async {
      final archive = await memoryArchive();

      // Phone writes at 100 with lexicographically smaller deviceId
      await archive.upsertPlace({
        'id': 'p1',
        'name': 'Phone Place',
        'latitude': 0,
        'longitude': 0,
        'radiusM': 150,
        'autoName': 'Phone Auto',
        'autoNameUpdatedAtUtcMillis': 100,
        'updatedAtUtcMillis': 100,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 100,
        'hlcCounter': 0,
        'hlcDeviceId': 'aaa',
        'deletedAtUtcMillis': null,
      });
      expect(
        (await archive.database.allPlaces()).single['name'],
        'Phone Place',
      );

      // Car writes same id at same timestamp with lexicographically larger deviceId should win (H-1: deviceId lexical decides)
      await archive.upsertPlace({
        'id': 'p1',
        'name': 'Car Place',
        'latitude': 0,
        'longitude': 0,
        'radiusM': 150,
        'autoName': 'Car Auto',
        'autoNameUpdatedAtUtcMillis': 100,
        'updatedAtUtcMillis': 100,
        'origin': kAnnotationOriginCar,
        'hlcMillis': 100,
        'hlcCounter': 0,
        'hlcDeviceId': 'zzz',
        'deletedAtUtcMillis': null,
      });
      expect((await archive.database.allPlaces()).single['name'], 'Car Place');
      expect(
        (await archive.database.allPlaces()).single['autoName'],
        'Car Auto',
      );

      // Older phone write is rejected
      await archive.upsertPlace({
        'id': 'p1',
        'name': 'Old Phone',
        'latitude': 0,
        'longitude': 0,
        'radiusM': 150,
        'autoName': 'Old Auto',
        'autoNameUpdatedAtUtcMillis': 50,
        'updatedAtUtcMillis': 50,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 50,
        'hlcCounter': 0,
        'hlcDeviceId': 'aaa',
        'deletedAtUtcMillis': null,
      });
      expect((await archive.database.allPlaces()).single['name'], 'Car Place');

      // Newer phone write beats car at older timestamp
      await archive.upsertPlace({
        'id': 'p1',
        'name': 'Newer Phone',
        'latitude': 0,
        'longitude': 0,
        'radiusM': 150,
        'autoName': 'Newer Auto',
        'autoNameUpdatedAtUtcMillis': 200,
        'updatedAtUtcMillis': 200,
        'origin': kAnnotationOriginPhone,
        'hlcMillis': 200,
        'hlcCounter': 0,
        'hlcDeviceId': 'aaa',
        'deletedAtUtcMillis': null,
      });
      expect(
        (await archive.database.allPlaces()).single['name'],
        'Newer Phone',
      );
    });

    test('saveInsightPlace preserves autoName when not provided', () async {
      final archive = await memoryArchive();
      final source = LocalTelemetrySource(archive);

      final first = await source.saveInsightPlace(
        name: 'Home',
        latitude: 1,
        longitude: 1,
        autoName: 'Auto1',
      );
      final id = first.id;
      expect(first.autoName, 'Auto1');

      // Update name without providing autoName should keep previous autoName
      final second = await source.saveInsightPlace(
        id: id,
        name: 'Casa',
        latitude: 1,
        longitude: 1,
      );
      expect(second.name, 'Casa');
      expect(second.autoName, 'Auto1');

      final places = await source.insightPlaces();
      expect(places.places.single.autoName, 'Auto1');
    });
  });
}
