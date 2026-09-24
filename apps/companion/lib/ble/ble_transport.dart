import 'dart:typed_data';

import 'ble_gatt_uuids.dart';

/// A vehicle candidate seen by a BLE scan.
class BleDiscoveredDevice {
  const BleDiscoveredDevice({
    required this.id,
    required this.name,
    required this.advertisesCapyService,
  });

  /// Builds a candidate from the raw advertisement, applying the car-ROM
  /// workarounds in one place beside [looksLikeVehicle].
  ///
  /// [advertisementName] is `advertisementData.advName`, [deviceName] is
  /// `device.advName`, and [serviceUuids] are the raw UUID strings. The
  /// fallback chain and the short-UUID (`cb01`) match live here so both
  /// adapters and tests share the same rule.
  factory BleDiscoveredDevice.fromRawAdvertisement({
    required String id,
    required String advertisementName,
    required String deviceName,
    required Iterable<String> serviceUuids,
  }) {
    final name = resolveDeviceName(advertisementName, deviceName);
    final advertises = advertisesCapyServiceFromUuids(serviceUuids);
    return BleDiscoveredDevice(
      id: id,
      name: name,
      advertisesCapyService: advertises,
    );
  }

  final String id;
  final String name;
  final bool advertisesCapyService;

  /// The `advName` fallback the car needs: the stack sometimes leaves
  /// `advertisementData.advName` empty and only `device.advName` carries the
  /// broadcast name.
  static String resolveDeviceName(
    String advertisementName,
    String deviceName,
  ) => advertisementName.isNotEmpty ? advertisementName : deviceName;

  /// Whether a single UUID string advertises the Capy service, including the
  /// short-form `cb01` the vendor stack emits instead of the full 128-bit
  /// UUID.
  static bool isCapyServiceUuid(String uuid) {
    final lower = uuid.toLowerCase();
    return lower == BleGattUuids.serviceUuid.toLowerCase() || lower == 'cb01';
  }

  /// Whether any UUID in [uuids] is the Capy service.
  static bool advertisesCapyServiceFromUuids(Iterable<String> uuids) =>
      uuids.any(isCapyServiceUuid);

  /// True when this advertisement is worth a connection attempt.
  ///
  /// The head unit advertises the Capy service UUID, but the vendor stack
  /// sometimes drops the service list from the advertisement and leaves only
  /// the local name, so the vehicle name families are accepted too.
  bool get looksLikeVehicle {
    if (advertisesCapyService) return true;
    final lower = name.toLowerCase();
    return lower.contains('geely') ||
        lower.contains('capy') ||
        lower.contains('mtk') ||
        lower.contains('ecarx');
  }

  @override
  String toString() =>
      'BleDiscoveredDevice($id, $name, $advertisesCapyService)';
}

/// One open link to the car, already subscribed to the telemetry stream.
abstract class BleConnection {
  /// Raw notification payloads from the telemetry characteristic.
  Stream<Uint8List> get frames;

  /// Completes when the link drops, for any reason.
  Future<void> get closed;

  Future<void> disconnect();
}

/// The seam between the live telemetry client and `flutter_blue_plus`.
///
/// The client owns scanning policy, retries and decoding; the transport owns
/// the radio. Tests drive a fake transport, so no concrete `flutter_blue_plus`
/// type reaches the state machine.
abstract class BleTransport {
  /// Devices already connected at the system level that expose the service.
  Future<List<BleDiscoveredDevice>> knownDevices();

  /// Scan results, until [stopScan] or [timeout].
  Stream<BleDiscoveredDevice> scan({required Duration timeout});

  Future<void> stopScan();

  /// Connects, discovers the Capy service, and enables notifications.
  ///
  /// Throws when any of those steps fails; the client retries.
  Future<BleConnection> connect(
    BleDiscoveredDevice device, {
    required Duration timeout,
  });
}
