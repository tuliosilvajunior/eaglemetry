/// Regenerates the derived vectors in `testdata/track_cases.json`.
///
/// The hand-written half of a case is `points`, `protected` and, where the
/// case has one, `piecewise_cuts`. Everything else is computed here from the
/// Dart reference so the fixture can never disagree with it. The Kotlin and
/// Python implementations are measured against the result.
///
/// Run from the repository root:
///   dart run packages/telemetry_core/tool/generate_track_fixture.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:telemetry_core/track.dart';

const _fixturePath = 'testdata/track_cases.json';

void main(List<String> args) {
  final file = File(_fixturePath);
  if (!file.existsSync()) {
    stderr.writeln('run from the repository root: $_fixturePath not found');
    exitCode = 2;
    return;
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  fixture['encoding_version'] = kTrackEncodingVersion;
  fixture['tolerance_m'] = kTrackSimplifyToleranceM;

  for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    final points = (c['points'] as List)
        .cast<Map<String, dynamic>>()
        .map(TrackPoint.fromJson)
        .toList();
    final protected = (c['protected'] as List).cast<bool>();

    c['encoded'] = TrackCodec.encode(points).toJson();

    final whole = TrackSimplifier.simplify(points, protected: protected);
    c['simplified_expected'] = TrackSimplifier.indexesIn(whole, points);

    if (c.containsKey('piecewise_cuts')) {
      final cuts = (c['piecewise_cuts'] as List).cast<int>();
      final joined = TrackSimplifier.simplifyInSections(
        points,
        cuts,
        protected: protected,
      );
      c['simplified_piecewise_expected'] = TrackSimplifier.indexesIn(
        joined,
        points,
      );
      c['piecewise_equal'] =
          c['simplified_piecewise_expected'].toString() ==
          c['simplified_expected'].toString();
    }
  }

  const encoder = JsonEncoder.withIndent(' ');
  file.writeAsStringSync('${encoder.convert(fixture)}\n');
  stdout.writeln('wrote $_fixturePath');
}
