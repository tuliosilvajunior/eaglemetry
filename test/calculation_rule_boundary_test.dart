import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Rule 2.1: **Dart may reduce. Dart never integrates.**
///
/// An energy is made from a rate. Whichever language turns a rate and a
/// duration into a quantity owns that quantity, and the car owns it: it reads
/// the bus at the bus rate, and the phone reads 1 Hz frames. Two integrals over
/// the same drive at two rates give two answers, which is what the `resampled`
/// mark used to admit. The second one was removed: one integral per drive.
///
/// This sweep is the proof. It reads the Dart sources and refuses any file
/// outside the allow-list that multiplies a rate by a duration, converts a
/// product into hours, or runs an accumulator.
///
/// **It is a text sweep, so it is approximate.** That is why the second half of
/// this file exists: every pattern is fired against a sample of the code it is
/// meant to catch, so a pattern that stops matching fails here rather than
/// turning the whole sweep into a silent pass. A previous version of this test
/// carried three patterns, two of them plain words, and let
/// `total += kw * stepSeconds / 3.6` through untouched.
void main() {
  /// Where an integral is allowed, and why. A file is not exempted because it
  /// is inconvenient to fix — each line states what the integral is for.
  const allowList = <String, String>{
    // The live smoothness pill folds the rate of change of pack power per
    // kilometre. It is a reading of the driving, published nowhere and stored
    // nowhere, and it has no counterpart on the car to disagree with.
    'driving_smoothness.dart': 'a live reading, never stored and never synced',
    // Reconciles two clocks into a duration. It integrates nothing; it carries
    // duration words that the rate-times-duration pattern would otherwise read
    // as a product.
    'session_duration.dart': 'reconciles clocks; produces no quantity',
    // The bucket type and its reductions. Summing minutes the car integrated is
    // a reduction, and this is where it belongs.
    'energy_buckets.dart': 'reduces the car\'s own minutes; does not integrate',
    // The road-load model: a physics function of speed, evaluated per point.
    // It yields a force and a power, never an accumulated energy.
    'physics_model.dart': 'evaluates a road-load model; accumulates nothing',
    // Reduces stored buckets over a trailing window. The window changes what a
    // point answers over; it never re-integrates. See CLAUDE.md.
    'efficiency_window.dart': 'reduces stored buckets over a window',
    // The mock. It has no car, no sync and no intervals, so it fabricates the
    // rows a car would have sent. Nothing it produces is stored or compared
    // against a real drive.
    'mock_telemetry_source.dart': 'fabricates rows the car would have sent',
    'mock_telemetry_data.dart': 'fabricates rows the car would have sent',
    // Sizes the FFI ring buffers: a window times a sample rate is a count of
    // samples, not a quantity. Nothing here touches energy.
    'live_roadcast_runtime.dart': 'sizes a ring buffer in samples',
    // The compass hold. Distance from speed, in memory, to decide whether a
    // held heading still describes the car. It is never stored, never synced
    // and never shown as a distance — CLAUDE.md puts this guard on the reader
    // for exactly that reason.
    'compass_reading.dart': 'in-memory creep guard for a held heading',
    // This file. It carries the patterns and the samples they are fired at.
    'calculation_rule_boundary_test.dart': 'carries the patterns themselves',
  };

  const scanDirs = ['lib', 'apps/companion/lib', 'packages/telemetry_core/lib'];

  late List<File> scanned;

  setUpAll(() {
    scanned = [
      for (final path in scanDirs)
        if (Directory(path).existsSync())
          ...Directory(path)
              .listSync(recursive: true)
              .whereType<File>()
              .where((file) => file.path.endsWith('.dart'))
              .where((file) => !file.path.endsWith('.g.dart')),
    ];
  });

  test('the sweep reads real files', () {
    // Without this, a wrong path or a changed layout makes every assertion
    // below pass over an empty list.
    expect(
      scanned.length,
      greaterThan(100),
      reason: 'the sweep found almost no Dart files; check $scanDirs',
    );
    for (final path in scanDirs) {
      expect(
        scanned.any((file) => file.path.startsWith(path)),
        isTrue,
        reason: '$path contributed no file to the sweep',
      );
    }
  });

  test('every allow-listed file exists', () {
    // An allow-list entry for a file that was renamed or deleted is a hole
    // nobody can see: it exempts nothing and hides that it exempts nothing.
    for (final name in allowList.keys) {
      expect(
        scanned.any((file) => _basename(file.path) == name) ||
            name == 'calculation_rule_boundary_test.dart',
        isTrue,
        reason: '$name is allow-listed but no such file is in the sweep',
      );
    }
  });

  test('every pattern still matches the code it is meant to catch', () {
    // The samples are written the way the offending code would really be
    // written, not as the regex source. If a pattern is narrowed until it only
    // matches its own spelling, one of these stops firing.
    const samples = <String, String>{
      'a plain trapezoidal fold':
          'total += (previousKw + kw) / 2 * deltaSeconds / 3600.0;',
      'the 3.6 spelling that slipped through':
          'total += kw * stepSeconds / 3.6;',
      'a named accumulator': 'final acc = EnergyBucketAccumulator();',
      'a rate times a duration, rate first':
          'final wh = powerKw * elapsedSeconds;',
      'a rate times a duration, duration first':
          'final wh = deltaSeconds * packPowerKw;',
      'distance from speed': 'distanceKm += speedKmh * dtHours;',
      'an hour conversion of a product':
          'energy = average * (millis / 3600000);',
    };
    samples.forEach((what, source) {
      expect(
        _violations(source),
        isNotEmpty,
        reason: 'no pattern catches $what: $source',
      );
    });
  });

  test('the patterns do not fire on ordinary reducing code', () {
    // The other half of the guard. A sweep that matched everything would also
    // pass this file's main assertion by having no allow-list left to check.
    const innocent = <String>[
      'final total = buckets.fold<double>(0, (sum, b) => sum + b.tractionWh);',
      'final whPerKm = netWh / distanceKm;',
      'final ratio = regeneratedWh / tractionWh;',
      'final minutes = durationMillis / 60000;',
      'final kw = voltageV * currentA / 1000;',
    ];
    for (final source in innocent) {
      expect(
        _violations(source),
        isEmpty,
        reason: 'a reduction was read as an integration: $source',
      );
    }
  });

  test('no Dart file outside the allow-list integrates', () {
    final violations = <String>[];
    for (final file in scanned) {
      if (allowList.containsKey(_basename(file.path))) continue;
      for (final hit in _violations(file.readAsStringSync())) {
        violations.add('${file.path}: $hit');
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Rule 2.1: these Dart files turn a rate and a duration into a '
          'quantity. The car already computes it and sends it. Read the '
          'interval stream, or add the file to the allow-list above with the '
          'reason it is an exception:\n${violations.join('\n')}',
    );
  });
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

/// The patterns, by what each one names.
///
/// `_rate` and `_span` below are written into each expression rather than
/// composed, because a raw string does not interpolate and composing them with
/// `+` reads worse than the pattern itself. Keep the two word lists identical
/// wherever they appear:
///
/// * rate: `kw`, `power`, `rate`, `speed`, `current`, `watt`, `amp`;
/// * span: `seconds`, `millis`, `minutes`, `hours`, `nanos`, `duration`,
///   `elapsed`, `delta`, `dt`.
final _patterns = <String, RegExp>{
  'an accumulator': RegExp(r'\b\w*[Aa]ccumulator\b'),
  'a trapezoidal fold': RegExp(r'trapezoid', caseSensitive: false),
  'a rate multiplied by a span': RegExp(
    r'\b\w*(?:[Kk][Ww]|[Pp]ower|[Rr]ate|[Ss]peed|[Cc]urrent|[Ww]att|[Aa]mp)\w*'
    r'\s*\*\s*'
    r'\w*(?:[Ss]econds|[Mm]illis|[Mm]inutes|[Hh]ours|[Nn]anos|[Dd]uration|'
    r'[Ee]lapsed|[Dd]elta|dt)\w*\b'
    r'|'
    r'\b\w*(?:[Ss]econds|[Mm]illis|[Mm]inutes|[Hh]ours|[Nn]anos|[Dd]uration|'
    r'[Ee]lapsed|[Dd]elta|dt)\w*'
    r'\s*\*\s*'
    r'\w*(?:[Kk][Ww]|[Pp]ower|[Rr]ate|[Ss]peed|[Cc]urrent|[Ww]att|[Aa]mp)\w*\b',
  ),
  'a product converted to hours': RegExp(
    r'\*[^;\n]*/\s*3[_.]?6(?:00)?(?:_?000)?(?:\.0)?\b|'
    r'/\s*3[_.]?6(?:00)?(?:_?000)?(?:\.0)?[^;\n]*\*',
  ),
  'an accumulation of a product over a span': RegExp(
    r'\+=[^;\n]*\*[^;\n]*'
    r'(?:[Ss]econds|[Mm]illis|[Mm]inutes|[Hh]ours|[Nn]anos|[Dd]uration|'
    r'[Ee]lapsed|[Dd]elta|dt)',
  ),
};

/// Every rule-2.1 hit in [source], by name.
///
/// Comments and string literals are stripped first: a doc comment that
/// describes the rule must not be read as breaking it.
List<String> _violations(String source) {
  final code = source
      .replaceAll(RegExp(r'///.*'), '')
      .replaceAll(RegExp(r'//.*'), '')
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(RegExp(r"'''[\s\S]*?'''"), "''")
      .replaceAll(RegExp(r'"""[\s\S]*?"""'), '""')
      .replaceAll(RegExp(r"'(?:[^'\\\n]|\\.)*'"), "''")
      .replaceAll(RegExp(r'"(?:[^"\\\n]|\\.)*"'), '""');
  return [
    for (final entry in _patterns.entries)
      if (entry.value.hasMatch(code)) entry.key,
  ];
}
