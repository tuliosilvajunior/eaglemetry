import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  group('InsightPlace autoName', () {
    test('displayName prefers name when present', () {
      const place = InsightPlace(
        id: 'p1',
        name: 'Home',
        latitude: 0,
        longitude: 0,
        autoName: 'Rua A',
        autoNameUpdatedAtUtcMillis: 100,
      );
      expect(place.displayName, 'Home');
      expect(place.effectiveName, 'Home');
    });

    test('displayName falls back to autoName when name empty', () {
      const place = InsightPlace(
        id: 'p1',
        name: '',
        latitude: 0,
        longitude: 0,
        autoName: 'Rua A',
        autoNameUpdatedAtUtcMillis: 100,
      );
      expect(place.displayName, 'Rua A');
    });

    test('displayName falls back to autoName when name is whitespace', () {
      const place = InsightPlace(
        id: 'p1',
        name: '   ',
        latitude: 0,
        longitude: 0,
        autoName: 'Rua B',
      );
      expect(place.displayName, 'Rua B');
    });

    test('displayName returns name when autoName null', () {
      const place = InsightPlace(
        id: 'p1',
        name: 'Work',
        latitude: 0,
        longitude: 0,
      );
      expect(place.displayName, 'Work');
      expect(place.autoName, isNull);
    });

    test('displayName empty when both empty', () {
      const place = InsightPlace(id: 'p1', name: '', latitude: 0, longitude: 0);
      expect(place.displayName, '');
    });

    test('fromMap parses autoName fields', () {
      final places = InsightPlacesResult.fromMap({
        'places': [
          {
            'id': 'p1',
            'name': 'Home',
            'latitude': -23.55,
            'longitude': -46.63,
            'radiusM': 150,
            'autoName': 'Avenida Paulista',
            'autoNameUpdatedAtUtcMillis': 123456,
            'autoNameSource': 'nominatim',
          },
          {
            'id': 'p2',
            'name': '',
            'latitude': -23.56,
            'longitude': -46.65,
            'radiusM': 150,
            'autoName': 'Rua Augusta',
            'autoNameUpdatedAtUtcMillis': 789,
          },
        ],
      }).places;

      expect(places[0].autoName, 'Avenida Paulista');
      expect(places[0].autoNameUpdatedAtUtcMillis, 123456);
      expect(places[0].autoNameSource, 'nominatim');
      expect(places[0].displayName, 'Home');

      expect(places[1].autoName, 'Rua Augusta');
      expect(places[1].displayName, 'Rua Augusta');
    });

    test('fromWire carries autoName', () {
      final wire = InsightPlaceWire(
        id: 'p1',
        name: 'Home',
        latitude: 0,
        longitude: 0,
        radiusM: 150,
        autoName: 'Suggested',
        autoNameUpdatedAtUtcMillis: 42,
        autoNameSource: 'nominatim',
      );
      final result = InsightPlacesResult.fromWire(
        InsightPlacesWire(places: [wire]),
      );
      expect(result.places.single.autoName, 'Suggested');
      expect(result.places.single.autoNameUpdatedAtUtcMillis, 42);
      expect(result.places.single.autoNameSource, 'nominatim');
    });

    test('placeNameAt returns displayName fallback', () {
      const places = [
        InsightPlace(
          id: 'p1',
          name: '',
          latitude: 0,
          longitude: 0,
          radiusM: 200,
          autoName: 'Auto',
        ),
      ];
      final name = placeNameAt(latitude: 0, longitude: 0, places: places);
      expect(name, 'Auto');
    });

    test('placeNameAt prefers name over autoName', () {
      const places = [
        InsightPlace(
          id: 'p1',
          name: 'Home',
          latitude: 0,
          longitude: 0,
          radiusM: 200,
          autoName: 'Auto',
        ),
      ];
      final name = placeNameAt(latitude: 0, longitude: 0, places: places);
      expect(name, 'Home');
    });

    test(
      'annotationShouldReplace respects car > phone > cloud for auto_name',
      () {
        // Same HLC timestamp, car wins over phone via ADR 0009 origin rank (auto_name)
        expect(
          annotationShouldReplaceWithOriginRank(
            existingHlcMillis: 100,
            existingHlcCounter: 0,
            existingHlcDeviceId: kAnnotationOriginPhone,
            existingOrigin: kAnnotationOriginPhone,
            incomingHlcMillis: 100,
            incomingHlcCounter: 0,
            incomingHlcDeviceId: kAnnotationOriginCar,
            incomingOrigin: kAnnotationOriginCar,
          ),
          isTrue,
        );
        // Same timestamp, phone wins over cloud via origin rank
        expect(
          annotationShouldReplaceWithOriginRank(
            existingHlcMillis: 100,
            existingHlcCounter: 0,
            existingHlcDeviceId: kAnnotationOriginCloud,
            existingOrigin: kAnnotationOriginCloud,
            incomingHlcMillis: 100,
            incomingHlcCounter: 0,
            incomingHlcDeviceId: kAnnotationOriginPhone,
            incomingOrigin: kAnnotationOriginPhone,
          ),
          isTrue,
        );
        // Newer HLC wins regardless of origin
        expect(
          annotationShouldReplace(
            existingHlcMillis: 100,
            existingHlcCounter: 0,
            existingHlcDeviceId: kAnnotationOriginCar,
            existingOrigin: kAnnotationOriginCar,
            incomingHlcMillis: 101,
            incomingHlcCounter: 0,
            incomingHlcDeviceId: kAnnotationOriginCloud,
            incomingOrigin: kAnnotationOriginCloud,
          ),
          isTrue,
        );
        // Older HLC loses even if origin higher
        expect(
          annotationShouldReplace(
            existingHlcMillis: 200,
            existingHlcCounter: 0,
            existingHlcDeviceId: kAnnotationOriginCloud,
            existingOrigin: kAnnotationOriginCloud,
            incomingHlcMillis: 100,
            incomingHlcCounter: 0,
            incomingHlcDeviceId: kAnnotationOriginCar,
            incomingOrigin: kAnnotationOriginCar,
          ),
          isFalse,
        );
      },
    );
  });
}
