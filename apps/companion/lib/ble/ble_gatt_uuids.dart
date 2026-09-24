/// GATT UUIDs of the Capy Live Telemetry Service on the vehicle.
///
/// There is no auth characteristic: the car cannot receive ATT requests, so
/// the stream is one-way and protection lives in the frame payload. See
/// [LiveTelemetryFrameCodec].
abstract class BleGattUuids {
  static const String serviceUuid = '0000cb01-0000-1000-8000-00805f9b34fb';
  static const String telemetryCharUuid =
      '0000cb02-0000-1000-8000-00805f9b34fb';
  static const String cccdUuid = '00002902-0000-1000-8000-00805f9b34fb';
}
