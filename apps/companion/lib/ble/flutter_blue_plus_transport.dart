import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_gatt_uuids.dart';
import 'ble_transport.dart';

/// The real radio behind [BleTransport], on `flutter_blue_plus`.
class FlutterBluePlusTransport implements BleTransport {
  const FlutterBluePlusTransport();

  static final Guid _serviceGuid = Guid(BleGattUuids.serviceUuid);
  static final Guid _telemetryGuid = Guid(BleGattUuids.telemetryCharUuid);

  @override
  Future<List<BleDiscoveredDevice>> knownDevices() async {
    try {
      final devices = await FlutterBluePlus.systemDevices([_serviceGuid]);
      return devices
          .map(
            (d) => BleDiscoveredDevice(
              id: d.remoteId.str,
              name: d.advName,
              advertisesCapyService: true,
            ),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  Stream<BleDiscoveredDevice> scan({required Duration timeout}) {
    final controller = StreamController<BleDiscoveredDevice>();
    StreamSubscription<List<ScanResult>>? sub;

    controller.onListen = () async {
      sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          controller.add(_toDiscovered(r));
        }
      }, onError: controller.addError);
      try {
        // No service filter: the vendor stack drops the service list from the
        // advertisement often enough that filtering hides the car entirely.
        await FlutterBluePlus.startScan(timeout: timeout);
      } catch (e, s) {
        controller.addError(e, s);
      }
    };
    controller.onCancel = () async {
      await sub?.cancel();
      await stopScan();
    };
    return controller.stream;
  }

  static BleDiscoveredDevice _toDiscovered(ScanResult r) =>
      BleDiscoveredDevice.fromRawAdvertisement(
        id: r.device.remoteId.str,
        advertisementName: r.advertisementData.advName,
        deviceName: r.device.advName,
        serviceUuids: r.advertisementData.serviceUuids.map((u) => u.str),
      );

  @override
  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  @override
  Future<BleConnection> connect(
    BleDiscoveredDevice device, {
    required Duration timeout,
  }) async {
    final target = BluetoothDevice.fromId(device.id);
    // autoConnect: false. With autoConnect the platform returns before the
    // link exists, and service discovery then fails against a dead handle.
    await target.connect(
      license: License.nonprofit,
      autoConnect: false,
      mtu: null,
      timeout: timeout,
    );
    try {
      final services = await target.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == _serviceGuid,
        orElse: () => throw StateError('Capy BLE service not found'),
      );
      final characteristic = service.characteristics.firstWhere(
        (c) => c.uuid == _telemetryGuid,
        orElse: () => throw StateError('Telemetry characteristic not found'),
      );
      try {
        await characteristic.setNotifyValue(true);
      } catch (_) {
        // The car ROM answers the CCCD write inside the stack and never tells
        // the app, so the write can report a failure the car does not have.
        // Notifications still arrive; keep the link and let the frames decide.
      }
      return _FlutterBluePlusConnection(target, characteristic);
    } catch (_) {
      await target.disconnect();
      rethrow;
    }
  }
}

class _FlutterBluePlusConnection implements BleConnection {
  _FlutterBluePlusConnection(
    this._device,
    BluetoothCharacteristic characteristic,
  ) : frames = characteristic.onValueReceived
          .where((data) => data.isNotEmpty)
          .map(Uint8List.fromList) {
    _closed = _device.connectionState
        .firstWhere((s) => s == BluetoothConnectionState.disconnected)
        .then((_) {});
  }

  final BluetoothDevice _device;

  @override
  final Stream<Uint8List> frames;

  late final Future<void> _closed;

  @override
  Future<void> get closed => _closed;

  @override
  Future<void> disconnect() async {
    try {
      await _device.disconnect();
    } catch (_) {}
  }
}
