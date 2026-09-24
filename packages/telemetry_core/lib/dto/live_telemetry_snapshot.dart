import 'dart:typed_data';

/// An instantaneous snapshot of vehicle telemetry designed for low-latency live
/// transmission over Bluetooth Low Energy (BLE).
class LiveTelemetrySnapshot {
  final int utcMillis;
  final double? socPercent;
  final double? speedKmh;
  final double? powerKw;
  final double? voltageV;
  final double? currentA;
  final double? latitude;
  final double? longitude;
  final double? altitudeM;
  final double? headingDeg;
  final bool isCharging;
  final bool isDcfc;
  final bool isParked;
  final double? ambientTempC;
  final double? odometerKm;

  const LiveTelemetrySnapshot({
    required this.utcMillis,
    this.socPercent,
    this.speedKmh,
    this.powerKw,
    this.voltageV,
    this.currentA,
    this.latitude,
    this.longitude,
    this.altitudeM,
    this.headingDeg,
    this.isCharging = false,
    this.isDcfc = false,
    this.isParked = false,
    this.ambientTempC,
    this.odometerKm,
  });

  static const int magicByte = 0xCB;
  static const int versionByte = 1;

  /// Serializes the snapshot to a compact binary payload.
  Uint8List toBinaryPayload() {
    int mask = 0;
    if (socPercent != null) mask |= (1 << 0);
    if (speedKmh != null) mask |= (1 << 1);
    if (powerKw != null) mask |= (1 << 2);
    if (voltageV != null) mask |= (1 << 3);
    if (currentA != null) mask |= (1 << 4);
    if (latitude != null && longitude != null) mask |= (1 << 5);
    if (altitudeM != null) mask |= (1 << 6);
    if (headingDeg != null) mask |= (1 << 7);
    if (ambientTempC != null) mask |= (1 << 8);
    if (odometerKm != null) mask |= (1 << 9);
    if (isCharging) mask |= (1 << 10);
    if (isDcfc) mask |= (1 << 11);
    if (isParked) mask |= (1 << 12);

    final byteData = ByteData(64);
    int offset = 0;

    byteData.setUint8(offset++, magicByte);
    byteData.setUint8(offset++, versionByte);
    byteData.setUint16(offset, mask, Endian.big);
    offset += 2;
    byteData.setInt64(offset, utcMillis, Endian.big);
    offset += 8;

    if (socPercent != null) {
      byteData.setInt16(offset, (socPercent! * 100).round(), Endian.big);
      offset += 2;
    }
    if (speedKmh != null) {
      byteData.setInt16(offset, (speedKmh! * 100).round(), Endian.big);
      offset += 2;
    }
    if (powerKw != null) {
      byteData.setInt32(offset, (powerKw! * 100).round(), Endian.big);
      offset += 4;
    }
    if (voltageV != null) {
      byteData.setInt32(offset, (voltageV! * 100).round(), Endian.big);
      offset += 4;
    }
    if (currentA != null) {
      byteData.setInt32(offset, (currentA! * 100).round(), Endian.big);
      offset += 4;
    }
    if (latitude != null && longitude != null) {
      byteData.setInt32(offset, (latitude! * 1000000).round(), Endian.big);
      offset += 4;
      byteData.setInt32(offset, (longitude! * 1000000).round(), Endian.big);
      offset += 4;
    }
    if (altitudeM != null) {
      byteData.setInt16(offset, (altitudeM! * 10).round(), Endian.big);
      offset += 2;
    }
    if (headingDeg != null) {
      byteData.setInt16(offset, (headingDeg! * 100).round(), Endian.big);
      offset += 2;
    }
    if (ambientTempC != null) {
      byteData.setInt16(offset, (ambientTempC! * 100).round(), Endian.big);
      offset += 2;
    }
    if (odometerKm != null) {
      byteData.setInt32(offset, (odometerKm! * 10).round(), Endian.big);
      offset += 4;
    }

    return Uint8List.view(byteData.buffer, 0, offset);
  }

  /// Deserializes a compact binary payload into a [LiveTelemetrySnapshot].
  factory LiveTelemetrySnapshot.fromBinaryPayload(Uint8List bytes) {
    if (bytes.length < 12) {
      throw FormatException('Invalid payload length: ${bytes.length}');
    }
    final byteData = ByteData.sublistView(bytes);
    int offset = 0;

    final magic = byteData.getUint8(offset++);
    if (magic != magicByte) {
      throw FormatException('Invalid magic byte: $magic');
    }
    final version = byteData.getUint8(offset++);
    if (version != versionByte) {
      throw FormatException('Unsupported version: $version');
    }
    final mask = byteData.getUint16(offset, Endian.big);
    offset += 2;
    final utcMillis = byteData.getInt64(offset, Endian.big);
    offset += 8;

    double? socPercent;
    if ((mask & (1 << 0)) != 0) {
      socPercent = byteData.getInt16(offset, Endian.big) / 100.0;
      offset += 2;
    }
    double? speedKmh;
    if ((mask & (1 << 1)) != 0) {
      speedKmh = byteData.getInt16(offset, Endian.big) / 100.0;
      offset += 2;
    }
    double? powerKw;
    if ((mask & (1 << 2)) != 0) {
      powerKw = byteData.getInt32(offset, Endian.big) / 100.0;
      offset += 4;
    }
    double? voltageV;
    if ((mask & (1 << 3)) != 0) {
      voltageV = byteData.getInt32(offset, Endian.big) / 100.0;
      offset += 4;
    }
    double? currentA;
    if ((mask & (1 << 4)) != 0) {
      currentA = byteData.getInt32(offset, Endian.big) / 100.0;
      offset += 4;
    }
    double? latitude;
    double? longitude;
    if ((mask & (1 << 5)) != 0) {
      latitude = byteData.getInt32(offset, Endian.big) / 1000000.0;
      offset += 4;
      longitude = byteData.getInt32(offset, Endian.big) / 1000000.0;
      offset += 4;
    }
    double? altitudeM;
    if ((mask & (1 << 6)) != 0) {
      altitudeM = byteData.getInt16(offset, Endian.big) / 10.0;
      offset += 2;
    }
    double? headingDeg;
    if ((mask & (1 << 7)) != 0) {
      headingDeg = byteData.getInt16(offset, Endian.big) / 100.0;
      offset += 2;
    }
    double? ambientTempC;
    if ((mask & (1 << 8)) != 0) {
      ambientTempC = byteData.getInt16(offset, Endian.big) / 100.0;
      offset += 2;
    }
    double? odometerKm;
    if ((mask & (1 << 9)) != 0) {
      odometerKm = byteData.getInt32(offset, Endian.big) / 10.0;
      offset += 4;
    }

    final isCharging = (mask & (1 << 10)) != 0;
    final isDcfc = (mask & (1 << 11)) != 0;
    final isParked = (mask & (1 << 12)) != 0;

    return LiveTelemetrySnapshot(
      utcMillis: utcMillis,
      socPercent: socPercent,
      speedKmh: speedKmh,
      powerKw: powerKw,
      voltageV: voltageV,
      currentA: currentA,
      latitude: latitude,
      longitude: longitude,
      altitudeM: altitudeM,
      headingDeg: headingDeg,
      isCharging: isCharging,
      isDcfc: isDcfc,
      isParked: isParked,
      ambientTempC: ambientTempC,
      odometerKm: odometerKm,
    );
  }
}
