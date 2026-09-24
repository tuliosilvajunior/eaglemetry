import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/track.dart';

/// The shared vectors. Kotlin (issue 175) and Python (issue 176) are measured
/// against this same file, so every vector in it is asserted here first.
///
/// Everything derived in the file is written by
/// `tool/generate_track_fixture.dart`. If a vector below fails after a change
/// to the codec, decide whether the codec regressed or the format moved on,
/// and only then regenerate.
Map<String, dynamic> _loadFixture() {
  final fromPackage = File('../../testdata/track_cases.json');
  final fromRoot = File('testdata/track_cases.json');
  final target = fromPackage.existsSync() ? fromPackage : fromRoot;
  if (!target.existsSync()) {
    fail('shared vectors not found; run tests from the package or repo root');
  }
  return jsonDecode(target.readAsStringSync()) as Map<String, dynamic>;
}

List<TrackPoint> _pointsOf(Map<String, dynamic> c) => (c['points'] as List)
    .cast<Map<String, dynamic>>()
    .map(TrackPoint.fromJson)
    .toList();

List<bool> _protectedOf(Map<String, dynamic> c) =>
    (c['protected'] as List).cast<bool>();

void main() {
  late Map<String, dynamic> fixture;
  late List<Map<String, dynamic>> cases;

  setUpAll(() {
    fixture = _loadFixture();
    cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();
  });

  Map<String, dynamic> caseNamed(String name) =>
      cases.firstWhere((c) => c['name'] == name);

  group('Shared vectors', () {
    test('declare version 1, the tolerance, and the precision', () {
      expect(fixture['encoding_version'], kTrackEncodingVersion);
      expect(fixture['tolerance_m'], kTrackSimplifyToleranceM);
      final p = fixture['precision'] as Map<String, dynamic>;
      expect(p['lat_lon_deg'], 1e-5);
      expect(p['time_seconds'], 0.001);
      expect(p['speed_kmh'], 0.1);
      expect(p['altitude_m'], 0.1);
    });

    test('cover the shapes the format has to survive', () {
      final names = cases.map((c) => c['name'] as String).toSet();
      expect(names, contains('empty'));
      expect(names, contains('one_point'));
      expect(names, contains('two_identical_points'));
      expect(names, contains('antimeridian_crossing'));
      expect(names, contains('equator_crossing'));
      expect(names, contains('antimeridian_bend_simplified'));
      expect(names, contains('piecewise_equivalence_protected_cuts'));
      expect(names, contains('piecewise_diverges_off_cut'));
    });

    test('every case declares points and protected of the same length', () {
      for (final c in cases) {
        final name = c['name'] as String;
        expect(
          _protectedOf(c).length,
          _pointsOf(c).length,
          reason: '$name protected length',
        );
      }
    });
  });

  group('Track codec', () {
    test('encoding every case reproduces its stored vector', () {
      for (final c in cases) {
        final name = c['name'] as String;
        final row = TrackCodec.encode(_pointsOf(c));
        final stored = TrackRow.fromJson(c['encoded'] as Map<String, dynamic>);
        expect(row.encodingVersion, stored.encodingVersion, reason: name);
        expect(row.pointCount, stored.pointCount, reason: '$name point_count');
        expect(row.t, stored.t, reason: '$name t');
        expect(row.path, stored.path, reason: '$name path');
        expect(row.speed, stored.speed, reason: '$name speed');
        expect(row.alt, stored.alt, reason: '$name alt');
      }
    });

    test(
      'decoding every stored vector returns the points, within precision',
      () {
        for (final c in cases) {
          final name = c['name'] as String;
          final points = _pointsOf(c);
          final decoded = TrackCodec.decode(
            TrackRow.fromJson(c['encoded'] as Map<String, dynamic>),
          );
          expect(decoded.length, points.length, reason: '$name length');
          for (var i = 0; i < points.length; i++) {
            _expectWithinPrecision(decoded[i], points[i], '$name point $i');
          }
        }
      },
    );

    test('encode then decode round-trips within precision', () {
      for (final c in cases) {
        final name = c['name'] as String;
        final points = _pointsOf(c);
        final decoded = TrackCodec.decode(TrackCodec.encode(points));
        expect(decoded.length, points.length, reason: '$name length');
        for (var i = 0; i < points.length; i++) {
          _expectWithinPrecision(decoded[i], points[i], '$name point $i');
        }
      }
    });

    test('a decoded point never claims protection', () {
      // Protection is not on the wire. Simplification is already done by the
      // time a row exists, so nothing downstream may believe otherwise.
      final c = caseNamed('piecewise_equivalence_protected_cuts');
      expect(_protectedOf(c).where((p) => p), isNotEmpty);
      final decoded = TrackCodec.decode(TrackCodec.encode(_pointsOf(c)));
      expect(decoded.every((p) => !p.protected), isTrue);
    });

    test('a short array fails the decode instead of shifting the map', () {
      final full = TrackCodec.encode(_pointsOf(caseNamed('equator_crossing')));
      for (final short in <TrackRow>[
        TrackRow(
          encodingVersion: full.encodingVersion,
          pointCount: full.pointCount,
          t: full.t.sublist(0, full.t.length - 1),
          path: full.path,
          speed: full.speed,
          alt: full.alt,
        ),
        TrackRow(
          encodingVersion: full.encodingVersion,
          pointCount: full.pointCount,
          t: full.t,
          path: full.path,
          speed: full.speed.sublist(0, full.speed.length - 1),
          alt: full.alt,
        ),
        TrackRow(
          encodingVersion: full.encodingVersion,
          pointCount: full.pointCount,
          t: full.t,
          path: full.path,
          speed: full.speed,
          alt: full.alt.sublist(0, full.alt.length - 1),
        ),
        TrackRow(
          encodingVersion: full.encodingVersion,
          pointCount: full.pointCount + 1,
          t: full.t,
          path: full.path,
          speed: full.speed,
          alt: full.alt,
        ),
      ]) {
        expect(
          () => TrackCodec.decode(short),
          throwsA(isA<TrackDecodeException>()),
        );
      }
    });

    test('a path holding the wrong number of points fails the decode', () {
      final full = TrackCodec.encode(_pointsOf(caseNamed('equator_crossing')));
      final trimmed = TrackRow(
        encodingVersion: full.encodingVersion,
        pointCount: full.pointCount,
        t: full.t,
        path: TrackCodec.encode(
          _pointsOf(caseNamed('equator_crossing')).sublist(0, 2),
        ).path,
        speed: full.speed,
        alt: full.alt,
      );
      expect(
        () => TrackCodec.decode(trimmed),
        throwsA(isA<TrackDecodeException>()),
      );
    });

    test('the decoder refuses a version it does not know', () {
      final full = TrackCodec.encode(_pointsOf(caseNamed('equator_crossing')));
      for (final v in <int>[0, kTrackEncodingVersion + 1, 99]) {
        expect(
          () => TrackCodec.decode(
            TrackRow(
              encodingVersion: v,
              pointCount: full.pointCount,
              t: full.t,
              path: full.path,
              speed: full.speed,
              alt: full.alt,
            ),
          ),
          throwsA(isA<TrackDecodeException>()),
          reason: 'version $v',
        );
      }
    });
  });

  group('Track simplifier', () {
    test('every case simplifies to its stored vector', () {
      for (final c in cases) {
        final name = c['name'] as String;
        final points = _pointsOf(c);
        final kept = TrackSimplifier.simplify(
          points,
          protected: _protectedOf(c),
        );
        expect(
          TrackSimplifier.indexesIn(kept, points),
          (c['simplified_expected'] as List).cast<int>(),
          reason: '$name simplified_expected',
        );
      }
    });

    test('the first and the last point always survive', () {
      for (final c in cases) {
        final name = c['name'] as String;
        final points = _pointsOf(c);
        if (points.isEmpty) continue;
        final kept = TrackSimplifier.simplify(
          points,
          protected: _protectedOf(c),
        );
        expect(kept.first, points.first, reason: '$name first');
        expect(kept.last, points.last, reason: '$name last');
      }
    });

    test('every protected point survives', () {
      for (final c in cases) {
        final name = c['name'] as String;
        final points = _pointsOf(c);
        final protected = _protectedOf(c);
        final kept = TrackSimplifier.simplify(points, protected: protected);
        for (var i = 0; i < points.length; i++) {
          if (protected[i] || points[i].protected) {
            expect(kept, contains(points[i]), reason: '$name index $i');
          }
        }
      }
    });

    test('a protected list adds to the point flag, it never disarms it', () {
      // A bend of about 22 m sits at index 1, so the flag is what keeps it.
      const flagged = <TrackPoint>[
        TrackPoint(
          latitude: 0,
          longitude: 0,
          tSeconds: 0,
          speedKmh: 10,
          altitudeM: 0,
        ),
        TrackPoint(
          latitude: 0.0000001,
          longitude: 0.001,
          tSeconds: 1,
          speedKmh: 10,
          altitudeM: 0,
          protected: true,
        ),
        TrackPoint(
          latitude: 0,
          longitude: 0.002,
          tSeconds: 2,
          speedKmh: 10,
          altitudeM: 0,
        ),
      ];
      expect(TrackSimplifier.simplify(flagged).length, 3);
      expect(
        TrackSimplifier.simplify(
          flagged,
          protected: const <bool>[false, false, false],
        ).length,
        3,
        reason: 'an all-false list must not drop a point that carries the flag',
      );
      expect(
        TrackSimplifier.simplify(
          flagged.map((p) => p.copyWith(protected: false)).toList(),
          protected: const <bool>[false, true, false],
        ).length,
        3,
        reason: 'the list alone protects too',
      );
      expect(
        TrackSimplifier.simplify(
          flagged.map((p) => p.copyWith(protected: false)).toList(),
        ).length,
        2,
        reason: 'with neither, the bend is inside tolerance and is dropped',
      );
    });

    test('sections cut on protected indexes join to the whole-path result', () {
      final c = caseNamed('piecewise_equivalence_protected_cuts');
      final points = _pointsOf(c);
      final protected = _protectedOf(c);
      final cuts = (c['piecewise_cuts'] as List).cast<int>();

      final whole = TrackSimplifier.simplify(points, protected: protected);
      final joined = TrackSimplifier.simplifyInSections(
        points,
        cuts,
        protected: protected,
      );

      expect(c['piecewise_equal'], isTrue);
      expect(joined, whole);
      expect(
        TrackSimplifier.indexesIn(joined, points),
        (c['simplified_piecewise_expected'] as List).cast<int>(),
      );
      // The case has to be worth asserting: the path must really shrink.
      expect(whole.length, lessThan(points.length));
    });

    test('sections cut anywhere else do not, and the vector says so', () {
      // Douglas-Peucker is not incremental. This is the counter-example that
      // stops issue 178 from simplifying as the Session runs.
      final c = caseNamed('piecewise_diverges_off_cut');
      final points = _pointsOf(c);
      final protected = _protectedOf(c);
      final cuts = (c['piecewise_cuts'] as List).cast<int>();

      final whole = TrackSimplifier.simplify(points, protected: protected);
      final joined = TrackSimplifier.simplifyInSections(
        points,
        cuts,
        protected: protected,
      );

      expect(c['piecewise_equal'], isFalse);
      expect(joined, isNot(whole));
      expect(
        TrackSimplifier.indexesIn(joined, points),
        (c['simplified_piecewise_expected'] as List).cast<int>(),
      );
      // Cutting early keeps points the whole path would have discarded.
      expect(joined.length, greaterThan(whole.length));
    });

    test('a bend on the 180th meridian is measured across the seam', () {
      // A planar distance would read the seam as a jump of 360 degrees and
      // keep every point. The vector holds the shape a real bend gives.
      final c = caseNamed('antimeridian_bend_simplified');
      final points = _pointsOf(c);
      final kept = TrackSimplifier.simplify(points);
      expect(kept.length, lessThan(points.length));
      expect(
        TrackSimplifier.indexesIn(kept, points),
        (c['simplified_expected'] as List).cast<int>(),
      );
      expect(
        points.map((p) => p.longitude.sign).toSet().length,
        2,
        reason: 'the case must actually cross the meridian',
      );
    });

    test('indexesIn maps by position, so a repeated point is not confused', () {
      // A stop writes the same coordinate twice. Searching by value would
      // report index 0 for both, and the vectors would read as a shorter
      // path than the one that was kept.
      const repeated = TrackPoint(
        latitude: 1,
        longitude: 1,
        tSeconds: 4,
        speedKmh: 0,
        altitudeM: 7,
      );
      const other = TrackPoint(
        latitude: 2,
        longitude: 2,
        tSeconds: 8,
        speedKmh: 0,
        altitudeM: 7,
      );
      const all = <TrackPoint>[repeated, other, repeated];
      expect(all.first, all.last);
      expect(TrackSimplifier.indexesIn(all, all), <int>[0, 1, 2]);
      expect(TrackSimplifier.indexesIn(const [repeated, repeated], all), <int>[
        0,
        2,
      ]);
    });
  });
}

void _expectWithinPrecision(TrackPoint got, TrackPoint want, String reason) {
  // Declared precision is half a step, plus room for floating point.
  const eps = 1e-9;
  expect(
    (got.latitude - want.latitude).abs(),
    lessThanOrEqualTo(0.5 / kTrackPolylineFactor + eps),
    reason: '$reason lat',
  );
  expect(
    (got.longitude - want.longitude).abs(),
    lessThanOrEqualTo(0.5 / kTrackPolylineFactor + eps),
    reason: '$reason lon',
  );
  expect(
    (got.tSeconds - want.tSeconds).abs(),
    lessThanOrEqualTo(0.5 / kTrackTimeFactor + eps),
    reason: '$reason t',
  );
  expect(
    (got.speedKmh - want.speedKmh).abs(),
    lessThanOrEqualTo(0.5 / kTrackSpeedFactor + eps),
    reason: '$reason speed',
  );
  expect(
    (got.altitudeM - want.altitudeM).abs(),
    lessThanOrEqualTo(0.5 / kTrackAltFactor + eps),
    reason: '$reason alt',
  );
}
