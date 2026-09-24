import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Compact live value published from the normalized VEHICLE_SPEED property.
class LiveVehicleSpeedReading {
  const LiveVehicleSpeedReading({
    required this.speedKmh,
    required this.quality,
    required this.source,
    required this.receivedAtUtcMillis,
    required this.receivedAtElapsedNanos,
    required this.sourceTimestampNanos,
  });

  factory LiveVehicleSpeedReading.fromMap(Map<Object?, Object?> map) =>
      LiveVehicleSpeedReading(
        speedKmh: _double(map['speedKmh']),
        quality: map['quality']?.toString() ?? 'UNAVAILABLE',
        source: map['source']?.toString() ?? 'UNKNOWN',
        receivedAtUtcMillis: _int(map['receivedAtUtcMillis']) ?? 0,
        receivedAtElapsedNanos: _int(map['receivedAtElapsedNanos']) ?? 0,
        sourceTimestampNanos: _int(map['sourceTimestampNanos']),
      );

  final double? speedKmh;
  final String quality;
  final String source;
  final int receivedAtUtcMillis;
  final int receivedAtElapsedNanos;
  final int? sourceTimestampNanos;

  int get motionTimestampNanos =>
      sourceTimestampNanos ?? receivedAtElapsedNanos;

  bool isUsableAt(
    int nowUtcMillis, {
    Duration maximumAge = const Duration(seconds: 3),
  }) {
    final speed = speedKmh;
    final age = nowUtcMillis - receivedAtUtcMillis;
    return speed != null &&
        speed.isFinite &&
        speed >= 0 &&
        speed <= 250 &&
        quality == 'MEASURED' &&
        (source == 'VHAL_CALLBACK' || source == 'VHAL_POLLING') &&
        age >= 0 &&
        age <= maximumAge.inMilliseconds;
  }

  static double? _double(Object? value) => switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text),
    _ => null,
  };

  static int? _int(Object? value) => switch (value) {
    int number => number,
    num number => number.toInt(),
    String text => int.tryParse(text),
    _ => null,
  };
}

/// Dedicated narrow EventChannel; avoids parsing the full telemetry snapshot
/// for every speed callback on the 60 Hz live surface.
class LiveVehicleSpeedApi {
  const LiveVehicleSpeedApi();

  static const EventChannel _channel = EventChannel(
    'com.timhss.capyenergy/telemetry/vehicle-speed',
  );

  static final Stream<LiveVehicleSpeedReading> _readings = _channel
      .receiveBroadcastStream()
      .map((event) {
        if (event is! Map) {
          throw const FormatException('Vehicle speed event is not a map');
        }
        return LiveVehicleSpeedReading.fromMap(event);
      });

  Stream<LiveVehicleSpeedReading> stream() {
    if (kIsWeb) return const Stream<LiveVehicleSpeedReading>.empty();
    return _readings;
  }
}
