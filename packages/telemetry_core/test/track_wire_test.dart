import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// Reading the row shape the car puts on the sync wire. Issue 179.
///
/// The wire is not the fixture shape: the keys are the Room entity's, and the
/// three arrays arrive as JSON strings because each is one TEXT column on the
/// car. Everything here is about telling a row this build can read from one it
/// cannot.
void main() {
  List<TrackPoint> drive() => [
    for (var i = 0; i < 12; i++)
      TrackPoint(
        latitude: -23.5 + i * 0.0004,
        longitude: -46.6 + i * 0.0003,
        tSeconds: i * 5.0,
        speedKmh: 51.3,
        altitudeM: 700.0 + i * 2.5,
      ),
  ];

  Map<String, Object?> wire(List<TrackPoint> points) {
    final row = TrackCodec.encode(points);
    return {
      'sessionId': 'trip-a',
      'encodingVersion': row.encodingVersion,
      'pointCount': row.pointCount,
      't': jsonEncode(row.t),
      'path': row.path,
      'speed': jsonEncode(row.speed),
      'alt': jsonEncode(row.alt),
      'updatedAtUtcMillis': 1000,
    };
  }

  test('a wire row decodes to the points that were encoded', () {
    final recorded = drive();

    final decoded = TrackCodec.decode(trackRowFromWire(wire(recorded)));

    expect(decoded.length, recorded.length);
    for (var i = 0; i < recorded.length; i++) {
      expect(decoded[i].latitude, closeTo(recorded[i].latitude, 1e-5));
      expect(decoded[i].longitude, closeTo(recorded[i].longitude, 1e-5));
      expect(decoded[i].tSeconds, closeTo(recorded[i].tSeconds, 0.001));
      expect(decoded[i].speedKmh, closeTo(recorded[i].speedKmh, 0.05));
      expect(decoded[i].altitudeM, closeTo(recorded[i].altitudeM, 0.05));
    }
  });

  test('an array already parsed into a list is read the same way', () {
    final row = wire(drive());
    final asLists = {
      ...row,
      't': jsonDecode(row['t']! as String),
      'speed': jsonDecode(row['speed']! as String),
      'alt': jsonDecode(row['alt']! as String),
    };

    expect(
      TrackCodec.decode(trackRowFromWire(asLists)).length,
      TrackCodec.decode(trackRowFromWire(row)).length,
    );
  });

  test('an empty route is a row, not a failure', () {
    final decoded = TrackCodec.decode(trackRowFromWire(wire(const [])));

    expect(decoded, isEmpty);
  });

  test('a row missing the count is refused rather than guessed at', () {
    final row = {...wire(drive())}..remove('pointCount');

    expect(() => trackRowFromWire(row), throwsA(isA<TrackDecodeException>()));
  });

  /// The arrays are positional, so a short one shifts every reading onto the
  /// wrong point. A route drawn from a shifted array is not a worse route, it
  /// is a route through places the vehicle never went.
  test('an array shorter than the count is refused', () {
    final row = {...wire(drive())};
    final speed = (jsonDecode(row['speed']! as String) as List)..removeLast();
    row['speed'] = jsonEncode(speed);

    expect(
      () => TrackCodec.decode(trackRowFromWire(row)),
      throwsA(isA<TrackDecodeException>()),
    );
  });

  test('an array holding something that is not a number is refused', () {
    final row = {...wire(drive())};
    row['alt'] = '["north"]';

    expect(() => trackRowFromWire(row), throwsA(isA<TrackDecodeException>()));
  });

  test('a version this build does not know is refused', () {
    final row = {...wire(drive())};
    row['encodingVersion'] = kTrackEncodingVersion + 1;

    expect(
      () => TrackCodec.decode(trackRowFromWire(row)),
      throwsA(isA<TrackDecodeException>()),
    );
  });
}
