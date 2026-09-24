import 'package:telemetry_core/telemetry_core.dart';

/// Adapter that maps a [LiveTelemetrySnapshot] to the ABRP (A Better
/// Routeplanner) Telemetry API schema.
///
/// Lives in the companion app so `telemetry_core` stays vendor-free;
/// only `toBinaryPayload` / `fromBinaryPayload` are shared with the car build.
class AbrpPayload {
  const AbrpPayload._();

  /// Returns a map matching the Iternio `tlm` payload expected by `POST /1/tlm/send`.
  static Map<String, dynamic> from(
    LiveTelemetrySnapshot snapshot, {
    int? nowMillis,
  }) => fromSnapshot(snapshot, nowMillis: nowMillis);

  /// Returns a map matching the Iternio `tlm` payload expected by `POST /1/tlm/send`.
  ///
  /// [nowMillis] is the phone clock, and it is the upper bound of `utc`. Iternio
  /// answers `400 utc property should be a UNIX timestamp in seconds and not in
  /// the future` and drops the whole sample when `utc` runs ahead of the server.
  /// The head unit clock jumps after a reboot, so the car time is clamped to the
  /// phone time, which comes from the network.
  static Map<String, dynamic> fromSnapshot(
    LiveTelemetrySnapshot snapshot, {
    int? nowMillis,
  }) {
    final now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final utcMillis = snapshot.utcMillis > now ? now : snapshot.utcMillis;
    final map = <String, dynamic>{
      'utc': utcMillis / 1000.0,
      'is_charging': snapshot.isCharging ? 1 : 0,
      'is_dcfc': snapshot.isDcfc ? 1 : 0,
      'is_parked': snapshot.isParked ? 1 : 0,
    };
    if (snapshot.socPercent != null) map['soc'] = snapshot.socPercent;
    if (snapshot.speedKmh != null) map['speed'] = snapshot.speedKmh;
    if (snapshot.powerKw != null) map['power'] = snapshot.powerKw;
    if (snapshot.voltageV != null) map['voltage'] = snapshot.voltageV;
    if (snapshot.currentA != null) map['current'] = snapshot.currentA;
    if (snapshot.latitude != null) map['lat'] = snapshot.latitude;
    if (snapshot.longitude != null) map['lon'] = snapshot.longitude;
    if (snapshot.altitudeM != null) map['elevation'] = snapshot.altitudeM;
    if (snapshot.headingDeg != null) map['heading'] = snapshot.headingDeg;
    if (snapshot.ambientTempC != null) map['ext_temp'] = snapshot.ambientTempC;
    if (snapshot.odometerKm != null) map['odometer'] = snapshot.odometerKm;
    return map;
  }
}
