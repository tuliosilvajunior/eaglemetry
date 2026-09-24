import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One frame of head-unit IMU data for the live sensor lab.
@immutable
class SensorLabFrame {
  const SensorLabFrame({
    required this.pitchDeg,
    required this.rollDeg,
    required this.haveGravity,
    required this.linX,
    required this.linY,
    required this.linZ,
    required this.vertical,
    required this.horizontal,
    required this.peakVertical,
    required this.peakHorizontal,
    required this.peakMagnitude,
    required this.sampleCount,
  });

  /// Front/back lean and side lean of the device, in degrees. Carries the fixed
  /// dash-mount offset; subtract a captured zero to read the car's own angle.
  final double pitchDeg;
  final double rollDeg;

  /// Whether the gravity sensor has produced a reading, so vertical/horizontal
  /// splitting is valid.
  final bool haveGravity;

  /// Latest gravity-removed acceleration in the device frame (m/s^2).
  final double linX;
  final double linY;
  final double linZ;

  /// Acceleration along gravity (potholes/bumps) and in the road plane
  /// (braking / accelerating / cornering), in m/s^2.
  final double vertical;
  final double horizontal;

  /// Peak-hold since the previous frame, so brief impact spikes are not missed.
  final double peakVertical;
  final double peakHorizontal;
  final double peakMagnitude;

  /// Number of raw IMU samples folded into this frame.
  final int sampleCount;

  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0.0;

  factory SensorLabFrame.fromMap(Map<String, Object?> map) => SensorLabFrame(
    pitchDeg: _d(map['pitchDeg']),
    rollDeg: _d(map['rollDeg']),
    haveGravity: map['haveGravity'] == true,
    linX: _d(map['linX']),
    linY: _d(map['linY']),
    linZ: _d(map['linZ']),
    vertical: _d(map['vertical']),
    horizontal: _d(map['horizontal']),
    peakVertical: _d(map['peakVertical']),
    peakHorizontal: _d(map['peakHorizontal']),
    peakMagnitude: _d(map['peakMagnitude']),
    sampleCount: (map['sampleCount'] as num?)?.toInt() ?? 0,
  );

  /// Pitch/roll with a calibration zero removed (car angle vs level ground).
  double zeroedPitch(double zeroPitch) => pitchDeg - zeroPitch;
  double zeroedRoll(double zeroRoll) => rollDeg - zeroRoll;
}

class SensorLabApi {
  static const _channel = EventChannel('com.timhss.capyenergy/sensors/live');
  static const _forceMock = bool.fromEnvironment('CAPY_MOCK_TELEMETRY');

  /// Live IMU stream. On web / mock builds, emits a synthesized signal so the
  /// screen is demoable off-device.
  Stream<SensorLabFrame> stream() {
    if (kIsWeb || _forceMock) {
      return _mockStream();
    }
    return _channel.receiveBroadcastStream().map(
      (event) =>
          SensorLabFrame.fromMap(Map<String, Object?>.from(event as Map)),
    );
  }

  Stream<SensorLabFrame> _mockStream() async* {
    final rnd = math.Random();
    var t = 0.0;
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      t += 0.04;
      final pitch = 6 * math.sin(t / 3);
      final roll = 3 * math.sin(t / 5);
      final vert =
          (rnd.nextDouble() - 0.5) * 2 + (rnd.nextDouble() < 0.02 ? 6.0 : 0.0);
      final horiz = (rnd.nextDouble()) * 1.5;
      yield SensorLabFrame(
        pitchDeg: pitch,
        rollDeg: roll,
        haveGravity: true,
        linX: vert,
        linY: horiz,
        linZ: 0,
        vertical: vert,
        horizontal: horiz,
        peakVertical: vert,
        peakHorizontal: horiz,
        peakMagnitude: math.max(vert.abs(), horiz),
        sampleCount: 5,
      );
    }
  }
}
