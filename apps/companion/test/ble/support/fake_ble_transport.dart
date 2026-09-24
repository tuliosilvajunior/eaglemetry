import 'dart:async';
import 'dart:typed_data';

import 'package:capy_companion/ble/ble_transport.dart';

/// A scripted radio, so the client state machine is testable without
/// `flutter_blue_plus` and without hardware.
class FakeBleTransport implements BleTransport {
  FakeBleTransport({
    this.known = const [],
    this.advertised = const [],
    this.failedConnects = 0,
    this.maxConnects = 1 << 30,
  });

  final List<BleDiscoveredDevice> known;
  final List<BleDiscoveredDevice> advertised;

  /// How many connect attempts throw before one succeeds.
  int failedConnects;

  /// After this many successful connects, later attempts always throw. Keeps
  /// the reconnect loop from spinning forever inside a test.
  final int maxConnects;

  int knownDevicesCalls = 0;
  int scanCalls = 0;
  int connectCalls = 0;
  int successfulConnects = 0;
  int stopScanCalls = 0;
  final List<FakeBleConnection> connections = [];

  @override
  Future<List<BleDiscoveredDevice>> knownDevices() async {
    knownDevicesCalls++;
    return known;
  }

  @override
  Stream<BleDiscoveredDevice> scan({required Duration timeout}) {
    scanCalls++;
    return Stream<BleDiscoveredDevice>.fromIterable(advertised);
  }

  @override
  Future<void> stopScan() async => stopScanCalls++;

  @override
  Future<BleConnection> connect(
    BleDiscoveredDevice device, {
    required Duration timeout,
  }) async {
    connectCalls++;
    if (failedConnects > 0) {
      failedConnects--;
      throw StateError('connect failed (scripted)');
    }
    if (successfulConnects >= maxConnects) {
      throw StateError('no more connects (scripted)');
    }
    successfulConnects++;
    final connection = FakeBleConnection();
    connections.add(connection);
    return connection;
  }
}

class FakeBleConnection implements BleConnection {
  final _frames = StreamController<Uint8List>.broadcast();
  final _closed = Completer<void>();

  bool disconnected = false;

  void push(Uint8List frame) => _frames.add(frame);

  void drop() {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> disconnect() async {
    disconnected = true;
    drop();
  }
}

/// The vehicle as a scan sees it, shared by the tests that need one.
abstract class BleDiscoveredDeviceFixture {
  static const car = BleDiscoveredDevice(
    id: 'AA:BB:CC:DD:EE:01',
    name: 'GEELY EX2',
    advertisesCapyService: true,
  );
}
