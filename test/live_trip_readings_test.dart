import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/live_trip_readings.dart';
import 'package:capy_energy/core/telemetry_api.dart';

Map<String, Object?> _signal(
  String signalId,
  Object? value, {
  String quality = 'MEASURED',
}) {
  return {
    'signalId': signalId,
    'value': value,
    'unit': '',
    'quality': quality,
    'source': 'test',
    'propertyId': 0,
    'propertyIdHex': '0x0',
    'areaId': 0,
    'timestampMillis': 1000,
    'sourceTimestampNanos': null,
    'details': '',
  };
}

LiveTelemetryFrame _frame({
  List<Map<String, Object?>> signals = const [],
  Map<String, Object?> location = const {},
  Map<String, Object?> trip = const {},
  int timestampMillis = 1000,
}) {
  return LiveTelemetryFrame.fromMap({
    'timestampMillis': timestampMillis,
    'signals': signals,
    'location': location,
    'trip': trip,
    'charge': const <String, Object?>{},
    'sessions': const <String, Object?>{},
    'frames': const <String, Object?>{},
    'recentEvents': const <Object?>[],
  });
}

void main() {
  group('LiveTripVhalReadings', () {
    test('mantém o último valor útil quando o frame não o traz', () {
      var readings = const LiveTripVhalReadings().merge(
        _frame(
          signals: [
            _signal('VEHICLE_SPEED', 42.0),
            _signal('HV_BATTERY_SOC', 63.4),
          ],
        ),
      );
      expect(readings.speedKmh, 42.0);

      // Frame seguinte só com velocidade: o SOC, que a coleta lê a cada 10 s, não
      // pode virar `--` só porque não veio neste.
      readings = readings.merge(
        _frame(signals: [_signal('VEHICLE_SPEED', 44.0)]),
      );
      expect(readings.speedKmh, 44.0);
      expect(readings.socPercent, 63.4);
    });

    test('recusa qualidade UNAVAILABLE e ERROR', () {
      final readings = const LiveTripVhalReadings().merge(
        _frame(
          signals: [
            _signal('VEHICLE_SPEED', 42.0, quality: 'UNAVAILABLE'),
            _signal('HV_BATTERY_SOC', 63.4, quality: 'ERROR'),
            _signal('ODOMETER', 12842.7, quality: 'DERIVED'),
          ],
        ),
      );

      expect(readings.speedKmh, isNull);
      expect(readings.socPercent, isNull);
      expect(readings.odometerKm, 12842.7);
    });

    test('lê a localização com as chaves do provider nativo', () {
      final readings = const LiveTripVhalReadings().merge(
        _frame(
          location: const {
            'latitude': -23.5617,
            'longitude': -46.6559,
            'altitudeM': 762.0,
            'gpsAccuracyM': 5.5,
            'lastFixAgeMillis': 800,
            'gpsEnabled': true,
          },
          trip: const {'tripState': 'ACTIVE'},
        ),
      );

      expect(readings.hasFix, isTrue);
      expect(readings.latitude, -23.5617);
      expect(readings.altitudeM, 762.0);
      expect(readings.gpsAccuracyM, 5.5);
      expect(readings.gpsFixAgeMillis, 800);
      expect(readings.gpsEnabled, isTrue);
      expect(readings.tripState, 'ACTIVE');
    });

    test('potência do pack é V×I e exige as duas medidas', () {
      final partial = const LiveTripVhalReadings().merge(
        _frame(signals: [_signal('HV_BATTERY_VOLTAGE', 386.2)]),
      );
      expect(partial.packPowerKw, isNull);

      final full = partial.merge(
        _frame(signals: [_signal('HV_BATTERY_CURRENT', -21.4)]),
      );
      expect(full.packPowerKw, closeTo(-8.264, 0.001));
    });

    test('temperatura externa cai para OUTSIDE_TEMPERATURE', () {
      final readings = const LiveTripVhalReadings().merge(
        _frame(signals: [_signal('OUTSIDE_TEMPERATURE', 21.5)]),
      );
      expect(readings.ambientTempC, 21.5);

      final preferred = readings.merge(
        _frame(signals: [_signal('AMBIENT_AIR_TEMPERATURE', 22.5)]),
      );
      expect(preferred.ambientTempC, 22.5);
    });
  });

  group('LiveTripSeries', () {
    test('decima a entrada pela cadência mínima', () {
      final series = LiveTripSeries(minStep: const Duration(seconds: 1));

      expect(series.add(1000, 10), isTrue);
      expect(series.add(1060, 11), isFalse, reason: '60 ms depois');
      expect(series.add(2000, 12), isTrue);
      expect(series.spots.map((spot) => spot.y), [10, 12]);
    });

    test('ignora valor ausente ou não finito', () {
      final series = LiveTripSeries();
      expect(series.add(1000, null), isFalse);
      expect(series.add(2000, double.nan), isFalse);
      expect(series.isEmpty, isTrue);
    });

    test('descarta o que saiu da janela e nunca esvazia a série', () {
      final series = LiveTripSeries(
        window: const Duration(seconds: 10),
        minStep: const Duration(seconds: 1),
      );
      for (var i = 0; i <= 20; i++) {
        series.add(1000 + i * 1000, i.toDouble());
      }

      expect(series.spots.length, lessThanOrEqualTo(11));
      expect(series.spots.last.y, 20);
      expect(series.minX, greaterThan(0));
      expect(series.maxX, 20);

      // Um ponto muito depois do fim da janela mantém pelo menos o valor atual.
      series.add(1000 + 600 * 1000, 99);
      expect(series.spots, hasLength(greaterThanOrEqualTo(1)));
      expect(series.spots.last.y, 99);
    });

    test('x é relativo à primeira amostra', () {
      final series = LiveTripSeries(minStep: const Duration(seconds: 1));
      series.add(50000, 1);
      series.add(53000, 2);

      expect(series.spots.first.x, 0);
      expect(series.spots.last.x, 3);
    });
  });
}
