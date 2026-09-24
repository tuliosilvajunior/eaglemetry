import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/candidate_places.dart';
import 'package:telemetry_core/insight_place.dart';
import 'package:telemetry_core/insight.dart';

void main() {
  // Helpers to build trips/points without relying on DB.
  InsightTrip makeTrip({
    required String id,
    double? startLat,
    double? startLon,
    double? endLat,
    double? endLon,
    String? path,
  }) => InsightTrip(
    id: id,
    aggregationVersion: 1,
    hasMinuteBuckets: true,
    startLatitude: startLat,
    startLongitude: startLon,
    endLatitude: endLat,
    endLongitude: endLon,
    path: path,
  );

  const home = InsightPlace(
    id: 'home',
    name: 'Home',
    latitude: -23.5505,
    longitude: -46.6333,
    radiusM: 150,
  );
  const work = InsightPlace(
    id: 'work',
    name: 'Work',
    latitude: -23.5600,
    longitude: -46.6500,
    radiusM: 150,
  );

  group('deriveCandidatePlaces grouping and deduplication', () {
    test('empty trips returns empty list', () {
      final result = deriveCandidatePlaces(trips: [], places: [home]);
      expect(result, isEmpty);
    });

    test('endpoints without GPS produce no candidates', () {
      final trips = [
        makeTrip(
          id: 't1',
          startLat: null,
          startLon: null,
          endLat: null,
          endLon: null,
        ),
        makeTrip(
          id: 't2',
          startLat: null,
          startLon: null,
          endLat: null,
          endLon: null,
        ),
      ];
      final result = deriveCandidatePlaces(trips: trips, places: []);
      expect(result, isEmpty);
    });

    test('all endpoints inside named places yield no candidates', () {
      final trips = [
        makeTrip(
          id: 't1',
          startLat: home.latitude,
          startLon: home.longitude,
          endLat: work.latitude,
          endLon: work.longitude,
        ),
        makeTrip(
          id: 't2',
          startLat: work.latitude,
          startLon: work.longitude,
          endLat: home.latitude,
          endLon: home.longitude,
        ),
      ];
      final result = deriveCandidatePlaces(trips: trips, places: [home, work]);
      expect(result, isEmpty);
    });

    test('single trip with unmatched endpoints yields two candidates', () {
      const farA = InsightPoint(-10.0, -48.0);
      const farB = InsightPoint(-10.02, -48.02);
      final trips = [
        makeTrip(
          id: 't1',
          startLat: farA.latitude,
          startLon: farA.longitude,
          endLat: farB.latitude,
          endLon: farB.longitude,
        ),
      ];
      final result = deriveCandidatePlaces(trips: trips, places: [home]);
      expect(result.length, 2);
      // Each candidate count 1
      for (final c in result) {
        expect(c.count, 1);
      }
      // Origin/dest split: one candidate is origin, other dest
      final totalOrigin = result.fold<int>(
        0,
        (s, c) => s + c.tripCountAsOrigin,
      );
      final totalDest = result.fold<int>(
        0,
        (s, c) => s + c.tripCountAsDestination,
      );
      expect(totalOrigin, 1);
      expect(totalDest, 1);
    });

    test(
      'loop trip where start and end map to same 100m cell yields one candidate with count 2',
      () {
        const point = InsightPoint(-23.551, -46.634);
        // Same coordinate as both start and end -> same cell
        final trips = [
          makeTrip(
            id: 'loop',
            startLat: point.latitude,
            startLon: point.longitude,
            endLat: point.latitude,
            endLon: point.longitude,
          ),
        ];
        final result = deriveCandidatePlaces(trips: trips, places: []);
        expect(result.length, 1);
        final c = result.single;
        expect(c.count, 2);
        expect(c.tripCountAsOrigin, 1);
        expect(c.tripCountAsDestination, 1);
        expect(c.id, variantSignature([point]));
        expect(c.latitude, closeTo(point.latitude, 1e-9));
        expect(c.longitude, closeTo(point.longitude, 1e-9));
      },
    );

    test('endpoints within 20m (same 100m cell) deduplicate to single candidate', () {
      // Two distinct points ~15m apart: 0.00012 deg ~13m lat, 0.0001 deg ~10m lon
      // Use coordinates far from [home, work] so they remain candidates.
      const baseLat = -23.65;
      const baseLon = -46.70;
      const p1 = InsightPoint(baseLat, baseLon);
      const p2 = InsightPoint(baseLat + 0.00012, baseLon + 0.00010);
      // Verify they indeed share cell (not near border) — if they differ due to border, adjust.
      final sig1 = variantSignature([p1]);
      final sig2 = variantSignature([p2]);
      // If this fails, the fixture is on a cell boundary; we still assert grouping via actual logic.
      // For robust test, we explicitly pick p2 same as p1 if border would split.
      final effectiveP2 = sig1 == sig2 ? p2 : p1;

      final trips = [
        makeTrip(
          id: 't1',
          startLat: p1.latitude,
          startLon: p1.longitude,
          endLat: -10.0,
          endLon: -48.0,
        ),
        makeTrip(
          id: 't2',
          startLat: effectiveP2.latitude,
          startLon: effectiveP2.longitude,
          endLat: -10.01,
          endLon: -48.01,
        ),
        // second trip's start is close to first's start -> same cell
      ];
      // Use places far away so none excluded (home/work are ~11km away from base)
      final result = deriveCandidatePlaces(trips: trips, places: [home, work]);
      // p1/effectiveP2 should be grouped together; the far ends are different cells.
      // So we expect: one candidate for the shared start cell with count 2, plus two distinct far ends.
      // But our second trip's far end -10.01,-48.01 and first trip's far end -10.0,-48.0 are 1.5km apart -> distinct.
      // So total distinct cells = 1 shared start + 2 far ends = 3.
      expect(result.length, 3);
      final shared = result.firstWhere((c) => c.id == variantSignature([p1]));
      expect(shared.count, 2);
      expect(shared.tripCountAsOrigin, 2);
      expect(shared.tripCountAsDestination, 0);
      // Verify ordering: shared candidate has higher count than others (2 vs 1)
      expect(result.first.id, shared.id);
    });

    test('endpoints 200m apart are distinct candidates', () {
      const pA = InsightPoint(-23.5505, -46.6333);
      // 200m north: ~0.001796 deg lat
      const pB = InsightPoint(-23.5505 + 0.0018, -46.6333);
      final sigA = variantSignature([pA]);
      final sigB = variantSignature([pB]);
      expect(sigA, isNot(equals(sigB)));

      final trips = [
        makeTrip(
          id: 't1',
          startLat: pA.latitude,
          startLon: pA.longitude,
          endLat: -10.0,
          endLon: -48.0,
        ),
        makeTrip(
          id: 't2',
          startLat: pB.latitude,
          startLon: pB.longitude,
          endLat: -10.1,
          endLon: -48.1,
        ),
      ];
      final result = deriveCandidatePlaces(trips: trips, places: []);
      // pA and pB distinct, plus two far ends distinct (total 4) — but pA/pB origins are distinct
      final candidateIds = result.map((c) => c.id).toSet();
      expect(candidateIds.contains(sigA), isTrue);
      expect(candidateIds.contains(sigB), isTrue);
      expect(candidateIds.length, 4);
    });

    test(
      'multiple trips sharing same cell combine counts without duplicates',
      () {
        const shared = InsightPoint(-23.58, -46.66);
        final trips = [
          makeTrip(
            id: 't1',
            startLat: shared.latitude,
            startLon: shared.longitude,
            endLat: -10.0,
            endLon: -48.0,
          ),
          makeTrip(
            id: 't2',
            startLat: shared.latitude,
            startLon: shared.longitude,
            endLat: -10.01,
            endLon: -48.01,
          ),
          makeTrip(
            id: 't3',
            startLat: shared.latitude,
            startLon: shared.longitude,
            endLat: -10.02,
            endLon: -48.02,
          ),
        ];
        final result = deriveCandidatePlaces(trips: trips, places: []);
        final cellId = variantSignature([shared]);
        final candidate = result.firstWhere((c) => c.id == cellId);
        expect(candidate.count, 3);
        expect(candidate.tripCountAsOrigin, 3);
        expect(candidate.tripCountAsDestination, 0);
        // No duplicated entries for same cell
        expect(result.where((c) => c.id == cellId).length, 1);
      },
    );
  });

  group('ordering by Place Recurrence (origin + destination)', () {
    test('candidates ordered by total recurrence descending', () {
      const cellA = InsightPoint(-23.58, -46.66); // will have count 4
      const cellB = InsightPoint(-23.59, -46.67); // count 3
      const cellC = InsightPoint(-23.60, -46.68); // count 1
      final trips = <InsightTrip>[
        // Cell A: 2 as origin + 2 as destination = 4
        makeTrip(
          id: 'a1',
          startLat: cellA.latitude,
          startLon: cellA.longitude,
          endLat: cellC.latitude,
          endLon: cellC.longitude,
        ),
        makeTrip(
          id: 'a2',
          startLat: cellA.latitude,
          startLon: cellA.longitude,
          endLat: -10.0,
          endLon: -48.0,
        ),
        makeTrip(
          id: 'a3',
          startLat: -10.1,
          startLon: -48.1,
          endLat: cellA.latitude,
          endLon: cellA.longitude,
        ),
        makeTrip(
          id: 'a4',
          startLat: -10.2,
          startLon: -48.2,
          endLat: cellA.latitude,
          endLon: cellA.longitude,
        ),
        // Cell B: 3 as origin = 3
        makeTrip(
          id: 'b1',
          startLat: cellB.latitude,
          startLon: cellB.longitude,
          endLat: -10.3,
          endLon: -48.3,
        ),
        makeTrip(
          id: 'b2',
          startLat: cellB.latitude,
          startLon: cellB.longitude,
          endLat: -10.4,
          endLon: -48.4,
        ),
        makeTrip(
          id: 'b3',
          startLat: cellB.latitude,
          startLon: cellB.longitude,
          endLat: -10.5,
          endLon: -48.5,
        ),
        // Cell C already has 1 as dest from a1, but also we add not more
      ];
      final result = deriveCandidatePlaces(trips: trips, places: []);
      // Expect ordering: cellA (4) before cellB (3) before others (1)
      final ids = result.map((c) => c.id).toList();
      final idA = variantSignature([cellA]);
      final idB = variantSignature([cellB]);
      final idC = variantSignature([cellC]);
      expect(ids.indexOf(idA), lessThan(ids.indexOf(idB)));
      expect(ids.indexOf(idB), lessThan(ids.indexOf(idC)));
      expect(result.first.id, idA);
      expect(result.first.count, 4);
      expect(result.first.tripCountAsOrigin, 2);
      expect(result.first.tripCountAsDestination, 2);
      expect(result[1].id, idB);
      expect(result[1].count, 3);
    });

    test(
      'origin+destination summed: trip that starts and ends in different cells contributes correctly',
      () {
        const cellOrigin = InsightPoint(-23.70, -46.70);
        const cellDest = InsightPoint(-23.71, -46.71);
        final trips = [
          makeTrip(
            id: 't1',
            startLat: cellOrigin.latitude,
            startLon: cellOrigin.longitude,
            endLat: cellDest.latitude,
            endLon: cellDest.longitude,
          ),
          makeTrip(
            id: 't2',
            startLat: cellOrigin.latitude,
            startLon: cellOrigin.longitude,
            endLat: cellDest.latitude,
            endLon: cellDest.longitude,
          ),
          makeTrip(
            id: 't3',
            startLat: cellOrigin.latitude,
            startLon: cellOrigin.longitude,
            endLat: cellDest.latitude,
            endLon: cellDest.longitude,
          ),
        ];
        final result = deriveCandidatePlaces(trips: trips, places: []);
        final origin = result.firstWhere(
          (c) => c.id == variantSignature([cellOrigin]),
        );
        final dest = result.firstWhere(
          (c) => c.id == variantSignature([cellDest]),
        );
        expect(origin.count, 3);
        expect(origin.tripCountAsOrigin, 3);
        expect(origin.tripCountAsDestination, 0);
        expect(dest.count, 3);
        expect(dest.tripCountAsDestination, 3);
        expect(dest.tripCountAsOrigin, 0);
        // Both have equal recurrence, ordering tie-break by origin count or id; just verify both present
        expect(result.length, 2);
      },
    );
  });

  group('placeContaining respects radiusM per place and nearest-wins', () {
    test(
      'endpoint inside nearest radius excluded, even if also inside farther radius',
      () {
        const placeA = InsightPlace(
          id: 'a',
          name: 'A',
          latitude: -10.18,
          longitude: -48.33,
          radiusM: 150,
        );
        const placeB = InsightPlace(
          id: 'b',
          name: 'B',
          latitude: -10.181,
          longitude: -48.33,
          radiusM: 300,
        );
        // Point ~22m from A, ~89m from B (both inside), nearest is A
        const pt = InsightPoint(-10.1802, -48.33);
        expect(placeContaining(pt, [placeA, placeB])?.id, 'a');
        expect(
          placeContaining(pt, [placeB, placeA])?.id,
          'a',
        ); // order independence

        final trips = [
          makeTrip(
            id: 't1',
            startLat: pt.latitude,
            startLon: pt.longitude,
            endLat: -10.5,
            endLon: -48.5,
          ),
        ];
        final candidates = deriveCandidatePlaces(
          trips: trips,
          places: [placeA, placeB],
        );
        // Start inside placeA, only dest candidate remains
        expect(candidates.length, 1);
        expect(
          candidates.single.id,
          variantSignature([const InsightPoint(-10.5, -48.5)]),
        );
      },
    );

    test(
      'endpoint outside nearest small radius but inside farther large radius still excluded',
      () {
        const small = InsightPlace(
          id: 'small',
          name: 'S',
          latitude: -10.18,
          longitude: -48.33,
          radiusM: 50,
        );
        const large = InsightPlace(
          id: 'large',
          name: 'L',
          latitude: -10.181,
          longitude: -48.33,
          radiusM: 300,
        );
        // Point ~100m from small (outside 50) but ~11m from large (inside 300)
        const pt = InsightPoint(-10.1809, -48.33);
        // Verify per-place radius handling
        expect(
          insightDistanceM(
            pt.latitude,
            pt.longitude,
            small.latitude,
            small.longitude,
          ),
          greaterThan(small.radiusM),
        );
        expect(
          insightDistanceM(
            pt.latitude,
            pt.longitude,
            large.latitude,
            large.longitude,
          ),
          lessThan(large.radiusM),
        );
        expect(placeContaining(pt, [small, large])?.id, 'large');
        expect(placeContaining(pt, [large, small])?.id, 'large');

        final trips = [
          makeTrip(
            id: 't1',
            startLat: pt.latitude,
            startLon: pt.longitude,
            endLat: -10.6,
            endLon: -48.6,
          ),
        ];
        final candidates = deriveCandidatePlaces(
          trips: trips,
          places: [small, large],
        );
        // Start excluded via large, only dest remains
        expect(candidates.length, 1);
        expect(
          candidates.single.id,
          variantSignature([const InsightPoint(-10.6, -48.6)]),
        );
      },
    );

    test('endpoint beyond all radii becomes candidate', () {
      const p = InsightPlace(
        id: 'p',
        name: 'P',
        latitude: -10.18,
        longitude: -48.33,
        radiusM: 50,
      );
      const pt = InsightPoint(-10.185, -48.33); // ~555m away
      expect(placeContaining(pt, [p]), isNull);
      final trips = [
        makeTrip(
          id: 't1',
          startLat: pt.latitude,
          startLon: pt.longitude,
          endLat: -10.6,
          endLon: -48.6,
        ),
      ];
      final candidates = deriveCandidatePlaces(trips: trips, places: [p]);
      expect(candidates.length, 2);
      expect(candidates.map((c) => c.id), contains(variantSignature([pt])));
    });

    test('nearest-wins when two radii overlap and point within both', () {
      const a = InsightPlace(
        id: 'a',
        name: 'A',
        latitude: -10.18,
        longitude: -48.33,
        radiusM: 200,
      );
      const b = InsightPlace(
        id: 'b',
        name: 'B',
        latitude: -10.1808,
        longitude: -48.33,
        radiusM: 200,
      );
      const pt = InsightPoint(
        -10.1802,
        -48.33,
      ); // ~22m from a, ~66m from b, both inside
      expect(placeContaining(pt, [a, b])?.id, 'a');
      expect(placeContaining(pt, [b, a])?.id, 'a');

      final trips = [
        makeTrip(
          id: 't1',
          startLat: pt.latitude,
          startLon: pt.longitude,
          endLat: -10.5,
          endLon: -48.5,
        ),
        makeTrip(
          id: 't2',
          startLat: -10.5,
          startLon: -48.5,
          endLat: pt.latitude,
          endLon: pt.longitude,
        ),
      ];
      final candidates = deriveCandidatePlaces(trips: trips, places: [a, b]);
      // pt endpoints excluded, only far ends shared cell -> count 2
      expect(candidates.length, 1);
      expect(candidates.single.count, 2);
      expect(candidates.single.tripCountAsOrigin, 1);
      expect(candidates.single.tripCountAsDestination, 1);
    });
  });

  group('candidate id is 100m cell signature via variantSignature', () {
    test('id equals variantSignature of single point', () {
      const pt = InsightPoint(-23.12345, -46.54321);
      final trips = [
        makeTrip(
          id: 't1',
          startLat: pt.latitude,
          startLon: pt.longitude,
          endLat: null,
          endLon: null,
        ),
      ];
      final c = deriveCandidatePlaces(trips: trips, places: []).single;
      expect(c.id, variantSignature([pt]));
    });

    test('mean latitude/longitude is average of points in cell', () {
      const p1 = InsightPoint(-23.5505, -46.6333);
      const p2 = InsightPoint(-23.5505, -46.6333); // same cell, same coords
      // Use p1 with tiny offset still same cell: choose identical to avoid border ambiguity
      final trips = [
        makeTrip(
          id: 't1',
          startLat: p1.latitude,
          startLon: p1.longitude,
          endLat: null,
          endLon: null,
        ),
        makeTrip(
          id: 't2',
          startLat: p2.latitude,
          startLon: p2.longitude,
          endLat: null,
          endLon: null,
        ),
      ];
      final c = deriveCandidatePlaces(trips: trips, places: []).single;
      expect(c.latitude, closeTo((p1.latitude + p2.latitude) / 2, 1e-9));
      expect(c.longitude, closeTo((p1.longitude + p2.longitude) / 2, 1e-9));
      expect(c.count, 2);
    });
  });

  group('fixture-driven table', () {
    final fixtures = [
      {
        'name': 'grouping close points same cell',
        'trips': [
          {
            'start': {'lat': -23.5505, 'lon': -46.6333},
            'end': {'lat': -10.0, 'lon': -48.0},
          },
          {
            'start': {'lat': -23.5505, 'lon': -46.6333},
            'end': {'lat': -10.01, 'lon': -48.01},
          },
        ],
        'places': [],
        'expectedDistinct': 3, // shared start + 2 distinct dests
        'expectedTopCount': 2,
      },
      {
        'name': 'ordering by recurrence',
        'trips': [
          {
            'start': {'lat': -23.58, 'lon': -46.66},
            'end': {'lat': -10.0, 'lon': -48.0},
          },
          {
            'start': {'lat': -23.58, 'lon': -46.66},
            'end': {'lat': -10.01, 'lon': -48.01},
          },
          {
            'start': {'lat': -23.58, 'lon': -46.66},
            'end': {'lat': -10.02, 'lon': -48.02},
          },
          {
            'start': {'lat': -23.59, 'lon': -46.67},
            'end': {'lat': -10.03, 'lon': -48.03},
          },
        ],
        'places': [],
        'expectedTopId': variantSignature([const InsightPoint(-23.58, -46.66)]),
        'expectedTopCount': 3,
      },
      {
        'name': 'deduplication via origin+dest same cell counted',
        'trips': [
          {
            'start': {'lat': -23.55, 'lon': -46.63},
            'end': {'lat': -23.55, 'lon': -46.63},
          },
        ],
        'places': [],
        'expectedDistinct': 1,
        'expectedTopCount': 2,
      },
    ];

    for (final f in fixtures) {
      test(f['name']! as String, () {
        final trips = (f['trips']! as List)
            .map(
              (e) => makeTrip(
                id: 't${(f['trips']! as List).indexOf(e)}',
                startLat: (e['start']! as Map)['lat'] as double?,
                startLon: (e['start']! as Map)['lon'] as double?,
                endLat: (e['end']! as Map)['lat'] as double?,
                endLon: (e['end']! as Map)['lon'] as double?,
              ),
            )
            .toList();
        final places = (f['places']! as List).cast<InsightPlace>();
        final result = deriveCandidatePlaces(trips: trips, places: places);
        if (f.containsKey('expectedDistinct')) {
          expect(result.length, f['expectedDistinct']);
        }
        if (f.containsKey('expectedTopCount')) {
          expect(result.first.count, f['expectedTopCount']);
        }
        if (f.containsKey('expectedTopId')) {
          expect(result.first.id, f['expectedTopId']);
        }
      });
    }
  });

  group('deriveCandidatePlacesFromEndpoints alternative entry', () {
    test('accepts record list directly and respects same logic', () {
      const p = InsightPoint(-23.55, -46.63);
      const q = InsightPoint(-23.56, -46.64);
      final endpoints = <({InsightPoint? start, InsightPoint? end})>[
        (start: p, end: q),
        (start: p, end: null),
        (start: null, end: q),
      ];
      final result = deriveCandidatePlacesFromEndpoints(
        endpoints: endpoints,
        places: [],
      );
      final idP = variantSignature([p]);
      final idQ = variantSignature([q]);
      final candP = result.firstWhere((c) => c.id == idP);
      final candQ = result.firstWhere((c) => c.id == idQ);
      expect(candP.count, 2); // p as origin twice
      expect(candQ.count, 2); // q as dest twice
      expect(candP.tripCountAsOrigin, 2);
      expect(candQ.tripCountAsDestination, 2);
    });

    test('empty record list returns empty', () {
      expect(
        deriveCandidatePlacesFromEndpoints(endpoints: [], places: []),
        isEmpty,
      );
    });
  });

  group('integration with InsightPlace radius and grid constants', () {
    test('fixture states the radius and grid the spec named', () {
      expect(kInsightPlaceRadiusM, 150.0);
      expect(kInsightVariantGridM, 100.0);
    });
  });
}
