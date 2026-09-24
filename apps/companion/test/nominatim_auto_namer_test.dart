import 'package:capy_companion/settings/nominatim_opt_in_store.dart';
import 'package:capy_companion/sync/local_telemetry_source.dart';
import 'package:capy_companion/sync/nominatim_auto_namer.dart';
import 'package:capy_companion/sync/nominatim_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/memory_archive.dart';

void main() {
  group('NominatimAutoNamer', () {
    test('preenche autoName de lugar existente com nome vazio', () async {
      final archive = await memoryArchive();
      final now = DateTime.now().millisecondsSinceEpoch;
      // Place with empty name, no autoName
      await archive.upsertPlace({
        'id': 'p1',
        'name': '',
        'latitude': -23.55,
        'longitude': -46.63,
        'radiusM': 150,
        'autoName': null,
        'autoNameUpdatedAtUtcMillis': null,
        'autoNameSource': null,
        'createdAtUtcMillis': now,
        'updatedAtUtcMillis': now,
        'origin': kAnnotationOriginPhone,
        'deletedAtUtcMillis': null,
      });
      // Need optIn enabled
      await archive.upsertPreference({
        'scope': NominatimGateway.preferenceScope,
        'key': NominatimGateway.preferenceKey,
        'value': 'true',
        'updatedAtUtcMillis': now,
        'origin': kAnnotationOriginPhone,
        'deletedAtUtcMillis': null,
      });
      final optIn = NominatimOptInStore(archive);
      await optIn.load();
      expect(optIn.enabled, isTrue);

      final source = LocalTelemetrySource(archive);
      final gateway = NominatimGateway(
        database: archive.database,
        fetcher: (uri, headers) async => 'Rua Auto, 100',
      );
      final namer = NominatimAutoNamer(
        source: source,
        gateway: gateway,
        optInStore: optIn,
      );
      final report = await namer.runOnce();
      expect(report.filledExisting, 1);
      expect(report.createdFromCandidates, 0);

      final source2 = LocalTelemetrySource(archive);
      final places = await source2.insightPlaces();
      expect(places.places.single.autoName, 'Rua Auto, 100');
      expect(places.places.single.displayName, 'Rua Auto, 100');
    });

    test('nao sobrescreve nome preenchido nem autoName existente', () async {
      final archive = await memoryArchive();
      final now = DateTime.now().millisecondsSinceEpoch;
      await archive.upsertPlace({
        'id': 'p1',
        'name': 'Casa',
        'latitude': 0,
        'longitude': 0,
        'radiusM': 150,
        'autoName': null,
        'createdAtUtcMillis': now,
        'updatedAtUtcMillis': now,
        'origin': kAnnotationOriginPhone,
        'deletedAtUtcMillis': null,
      });
      await archive.upsertPlace({
        'id': 'p2',
        'name': '',
        'latitude': 0.001,
        'longitude': 0.001,
        'radiusM': 150,
        'autoName': 'Ja Tem',
        'autoNameUpdatedAtUtcMillis': now,
        'autoNameSource': 'nominatim',
        'createdAtUtcMillis': now,
        'updatedAtUtcMillis': now,
        'origin': kAnnotationOriginPhone,
        'deletedAtUtcMillis': null,
      });
      await archive.upsertPreference({
        'scope': NominatimGateway.preferenceScope,
        'key': NominatimGateway.preferenceKey,
        'value': 'true',
        'updatedAtUtcMillis': now,
        'origin': kAnnotationOriginPhone,
        'deletedAtUtcMillis': null,
      });
      final optIn = NominatimOptInStore(archive);
      await optIn.load();

      var fetches = 0;
      final gateway = NominatimGateway(
        database: archive.database,
        fetcher: (uri, headers) async {
          fetches++;
          return 'Novo';
        },
      );
      final source = LocalTelemetrySource(archive);
      final namer = NominatimAutoNamer(
        source: source,
        gateway: gateway,
        optInStore: optIn,
      );
      final report = await namer.runOnce();
      expect(report.filledExisting, 0);
      expect(fetches, 0);
    });

    test('cria lugar a partir de candidate com autoName', () async {
      final archive = await memoryArchive();
      final now = DateTime.now().millisecondsSinceEpoch;
      // Create trips that generate candidates: need trips with endpoints
      // Insert a session row with start/end and path not inside any place
      // Use direct DB inserts for sessions/trips
      // For simplicity, we add a trip via archive helper? Use database upsertSession and then trips derived via LocalTelemetrySource
      // LocalTelemetrySource.insightTrips reads from sessions table
      await archive.database.upsertSession({
        'id': 'trip1',
        'kind': 'TRIP',
        'status': 'CLOSED',
        'startedAtUtcMillis': now - 10000,
        'endedAtUtcMillis': now - 5000,
        'startLatitude': -23.55,
        'startLongitude': -46.63,
        'endLatitude': -23.56,
        'endLongitude': -46.64,
        'path': '-23.55,-46.63;-23.56,-46.64',
        'rollupDistanceKm': 1,
        'rollupTractionWh': 100,
        'rollupRegenWh': 10,
        'socAgreesWithIntegral': 'YES',
      });
      // Need intervals to pass hasMinuteBuckets? Not required for candidate, but for insightTrips we need trips
      // For candidate derivation, trips are from insightTrips which assembles InsightTrip from sessions + gpsPath etc.
      // Insert intervals dummy to make hasMinuteBuckets true? Actually not needed for candidate, but for measured trip etc.
      // Add intervals
      await archive.database.upsertInterval({
        'sessionId': 'trip1',
        'startUtcMillis': now - 10000,
        'value': 1,
      });
      // Need preferences optIn
      await archive.upsertPreference({
        'scope': NominatimGateway.preferenceScope,
        'key': NominatimGateway.preferenceKey,
        'value': 'true',
        'updatedAtUtcMillis': now,
        'origin': kAnnotationOriginPhone,
        'deletedAtUtcMillis': null,
      });
      final optIn = NominatimOptInStore(archive);
      await optIn.load();

      // No places yet, so candidate should be derived
      final src = LocalTelemetrySource(archive);
      final before = await src.insightPlaces();
      expect(before.places, isEmpty);

      final gateway = NominatimGateway(
        database: archive.database,
        fetcher: (uri, headers) async {
          final lat = uri.queryParameters['lat'];
          if (lat == '-23.55') return 'Rua A, 10';
          if (lat == '-23.56') return 'Rua B, 20';
          return 'Rua X';
        },
      );
      final namer = NominatimAutoNamer(
        source: src,
        gateway: gateway,
        optInStore: optIn,
      );
      final report = await namer.runOnce();
      // Should create 2 candidates? Actually endpoints are two cells distinct, each count 1
      expect(report.createdFromCandidates, 2);

      final after = await src.insightPlaces();
      expect(after.places.length, 2);
      for (final p in after.places) {
        expect(p.autoName, isNotNull);
        expect(p.name, '');
        expect(p.displayName, p.autoName);
        expect(p.id, startsWith('auto-'));
      }
      // Second run should be idempotent (no more candidates, no empty autoName)
      final report2 = await namer.runOnce();
      expect(report2.createdFromCandidates, 0);
      expect(report2.filledExisting, 0);
    });

    test(
      'dedupe remove gemeo sem nome na mesma celula e preserva nomeado',
      () async {
        final archive = await memoryArchive();
        final now = DateTime.now().millisecondsSinceEpoch;
        // User named the auto place of this cell.
        await archive.upsertPlace({
          'id': 'auto-100,100',
          'name': 'Casa',
          'latitude': 0.0005,
          'longitude': 0.0005,
          'radiusM': 150,
          'autoName': 'Rua Velha, 1',
          'autoNameUpdatedAtUtcMillis': now,
          'autoNameSource': 'nominatim',
          'createdAtUtcMillis': now - 1000,
          'updatedAtUtcMillis': now,
          'origin': kAnnotationOriginPhone,
          'deletedAtUtcMillis': null,
        });
        // Twin from a racing older run: same cell, empty name.
        await archive.upsertPlace({
          'id': 'phone-place-7',
          'name': '',
          'latitude': 0.0006,
          'longitude': 0.0006,
          'radiusM': 150,
          'autoName': 'Rua Velha, 1',
          'autoNameUpdatedAtUtcMillis': now,
          'autoNameSource': 'nominatim',
          'createdAtUtcMillis': now - 500,
          'updatedAtUtcMillis': now,
          'origin': kAnnotationOriginPhone,
          'deletedAtUtcMillis': null,
        });
        await archive.upsertPreference({
          'scope': NominatimGateway.preferenceScope,
          'key': NominatimGateway.preferenceKey,
          'value': 'true',
          'updatedAtUtcMillis': now,
          'origin': kAnnotationOriginPhone,
          'deletedAtUtcMillis': null,
        });
        final optIn = NominatimOptInStore(archive);
        await optIn.load();
        final gateway = NominatimGateway(
          database: archive.database,
          fetcher: (uri, headers) async {
            return 'Rua Qualquer';
          },
        );
        final source = LocalTelemetrySource(archive);
        final namer = NominatimAutoNamer(
          source: source,
          gateway: gateway,
          optInStore: optIn,
        );

        final report = await namer.runOnce();
        expect(report.deduped, 1);

        final places = await source.insightPlaces();
        expect(places.places, hasLength(1));
        expect(places.places.single.id, 'auto-100,100');
        expect(places.places.single.name, 'Casa');
      },
    );

    test('respeita optIn desligado', () async {
      final archive = await memoryArchive();
      final now = DateTime.now().millisecondsSinceEpoch;
      await archive.upsertPlace({
        'id': 'p1',
        'name': '',
        'latitude': 0,
        'longitude': 0,
        'radiusM': 150,
        'createdAtUtcMillis': now,
        'updatedAtUtcMillis': now,
        'origin': kAnnotationOriginPhone,
        'deletedAtUtcMillis': null,
      });
      // optIn false (no preference)
      final optIn = NominatimOptInStore(archive);
      await optIn.load();
      expect(optIn.enabled, isFalse);
      var fetches = 0;
      final gateway = NominatimGateway(
        database: archive.database,
        fetcher: (uri, headers) async {
          fetches++;
          return 'Rua';
        },
      );
      final source = LocalTelemetrySource(archive);
      final namer = NominatimAutoNamer(
        source: source,
        gateway: gateway,
        optInStore: optIn,
      );
      final report = await namer.runOnce();
      expect(report.optInDisabled, isTrue);
      expect(fetches, 0);
      final places = await source.insightPlaces();
      expect(places.places.single.autoName, isNull);
    });
  });
}
