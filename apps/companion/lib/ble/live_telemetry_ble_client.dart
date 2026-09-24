import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'ble_transport.dart';
import 'flutter_blue_plus_transport.dart';
import 'live_telemetry_frame_codec.dart';

export 'ble_gatt_uuids.dart';

enum BleConnectionState { disconnected, scanning, connecting, streaming, error }

/// Keeps a live 1 Hz telemetry stream from the car on the phone.
///
/// The transport is one-way: the car pushes encrypted frames and the phone
/// never writes. The client therefore only has to find the car, hold the link
/// open, and decode. It reconnects on its own, because the link drops every
/// time the car powers down or the phone leaves range.
class LiveTelemetryBleClient extends ChangeNotifier {
  LiveTelemetryBleClient({
    BleTransport? transport,

    /// The pairing secret, when it is already known at construction. [start]
    /// sets it too, so this is only a convenience for tests and for a phone
    /// that is paired before the stream begins.
    String? sharedSecretBase64,
    this.scanTimeout = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 10),
    this.connectAttempts = 3,
    this.initialRetryDelay = const Duration(seconds: 2),
    this.maxRetryDelay = const Duration(seconds: 30),
    Future<void> Function(Duration)? sleep,
  }) : _transport = transport ?? const FlutterBluePlusTransport(),
       _reader = sharedSecretBase64 == null
           ? null
           : LiveTelemetryFrameReader(sharedSecretBase64),
       _sleep = sleep ?? Future<void>.delayed {
    _currentRetryDelay = initialRetryDelay;
  }

  final BleTransport _transport;
  final Duration scanTimeout;
  final Duration connectTimeout;

  /// Connection attempts per discovered device before scanning again. A weak
  /// signal makes the first attempts time out on this hardware.
  final int connectAttempts;
  final Duration initialRetryDelay;
  final Duration maxRetryDelay;
  final Future<void> Function(Duration) _sleep;

  BleConnectionState _state = BleConnectionState.disconnected;
  BleConnectionState get state => _state;

  final _snapshotController =
      StreamController<LiveTelemetrySnapshot>.broadcast();
  Stream<LiveTelemetrySnapshot> get snapshotStream =>
      _snapshotController.stream;

  bool _running = false;
  bool get isRunning => _running;
  Future<void>? _loop;
  BleConnection? _connection;
  LiveTelemetryFrameReader? _reader;
  late Duration _currentRetryDelay;
  Completer<void>? _retryWake;
  bool _retryRequested = false;

  /// Frames that arrived but did not decode under this phone's secret. They
  /// are normal: the car sends one frame per paired phone.
  int get rejectedFrameCount => _rejectedFrames;
  int _rejectedFrames = 0;

  /// Finds the car and keeps the stream alive until [stop].
  ///
  /// [sharedSecretBase64] is the pairing secret. It is both the key and
  /// the identity: only frames that decrypt under it belong to this phone.
  Future<void> start({required String sharedSecretBase64}) async {
    if (_running) return;
    _reader = LiveTelemetryFrameReader(sharedSecretBase64);
    _currentRetryDelay = initialRetryDelay;
    _retryRequested = false;
    _running = true;
    // A microtask, not a direct call: `start` is triggered from `initState`
    // and the first state change must not land inside a build phase.
    _loop = Future<void>.microtask(_runUntilStopped);
    return _loop;
  }

  /// Stops the stream and the reconnect loop.
  Future<void> stop() async {
    _running = false;
    if (_retryWake != null && !_retryWake!.isCompleted) {
      _retryWake!.complete();
    }
    _retryWake = null;
    _retryRequested = false;
    await _connection?.disconnect();
    _connection = null;
    await _transport.stopScan();
    await _loop;
    _loop = null;
    _currentRetryDelay = initialRetryDelay;
    _updateState(BleConnectionState.disconnected);
  }

  /// Wakes the reconnect loop and resets the backoff so the next attempt
  /// happens without waiting for a long delay.
  ///
  /// Does nothing when the radio is off. That keeps the two gates in
  /// `CompanionRuntime._followBleGates` as the only place that decides
  /// whether the radio may run.
  void retryNow() {
    if (!_running) return;
    _retryRequested = true;
    _currentRetryDelay = initialRetryDelay;
    final wake = _retryWake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _resetBackoff() {
    _retryRequested = false;
    _currentRetryDelay = initialRetryDelay;
  }

  Future<void> _runUntilStopped() async {
    _currentRetryDelay = initialRetryDelay;
    while (_running) {
      final streamed = await _oneSession();
      if (!_running) break;
      _currentRetryDelay = streamed
          ? initialRetryDelay
          : _nextDelay(_currentRetryDelay);
      if (_retryRequested) {
        _resetBackoff();
        continue;
      }
      _retryWake = Completer<void>();
      if (_retryRequested) {
        _resetBackoff();
        if (!_retryWake!.isCompleted) _retryWake!.complete();
      }
      await Future.any([_sleep(_currentRetryDelay), _retryWake!.future]);
      final wokeEarly = _retryWake!.isCompleted;
      _retryWake = null;
      if (wokeEarly) _resetBackoff();
    }
  }

  Duration _nextDelay(Duration current) {
    final doubled = current * 2;
    return doubled > maxRetryDelay ? maxRetryDelay : doubled;
  }

  /// Runs one find-connect-stream cycle. Returns true when frames arrived,
  /// which resets the retry backoff.
  Future<bool> _oneSession() async {
    BleConnection? connection;
    try {
      final device = await _findVehicle();
      if (device == null || !_running) {
        _updateState(BleConnectionState.disconnected);
        return false;
      }
      connection = await _connectWithRetries(device);
      if (connection == null || !_running) {
        _updateState(BleConnectionState.error);
        return false;
      }
      _connection = connection;
      // The car seeds its frame counter randomly on every start, so the
      // replay window has to start over with each new link.
      _reader?.resetCounters();
      return await _consume(connection);
    } catch (e) {
      debugPrint('BLE session error: $e');
      _updateState(BleConnectionState.error);
      return false;
    } finally {
      if (identical(_connection, connection)) _connection = null;
      await connection?.disconnect();
    }
  }

  Future<BleDiscoveredDevice?> _findVehicle() async {
    _updateState(BleConnectionState.scanning);

    for (final device in await _transport.knownDevices()) {
      if (device.looksLikeVehicle) return device;
    }

    try {
      await for (final device in _transport.scan(timeout: scanTimeout)) {
        if (!_running) break;
        if (device.looksLikeVehicle) {
          await _transport.stopScan();
          return device;
        }
      }
    } catch (e) {
      debugPrint('BLE scan error: $e');
    } finally {
      await _transport.stopScan();
    }
    return null;
  }

  Future<BleConnection?> _connectWithRetries(BleDiscoveredDevice device) async {
    _updateState(BleConnectionState.connecting);
    for (var attempt = 1; attempt <= connectAttempts && _running; attempt++) {
      try {
        return await _transport.connect(device, timeout: connectTimeout);
      } catch (e) {
        debugPrint('BLE connect attempt $attempt/$connectAttempts failed: $e');
        if (attempt < connectAttempts) await _sleep(initialRetryDelay);
      }
    }
    return null;
  }

  Future<bool> _consume(BleConnection connection) async {
    var streamed = false;
    final done = Completer<void>();
    final sub = connection.frames.listen(
      (frame) {
        if (_onFrame(frame)) streamed = true;
      },
      onError: (Object e) => debugPrint('BLE frame error: $e'),
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    await Future.any([done.future, connection.closed]);
    await sub.cancel();
    _updateState(BleConnectionState.disconnected);
    return streamed;
  }

  /// Decodes one notification. Returns true when it carried a snapshot for
  /// this phone.
  @visibleForTesting
  bool onFrameReceived(Uint8List frame) => _onFrame(frame);

  bool _onFrame(Uint8List frame) {
    final snapshot = _reader?.read(frame);
    if (snapshot == null) {
      _rejectedFrames++;
      return false;
    }
    _snapshotController.add(snapshot);
    _updateState(BleConnectionState.streaming);
    return true;
  }

  void _updateState(BleConnectionState newState) {
    if (_state == newState) return;
    _state = newState;
    notifyListeners();
  }

  @override
  void dispose() {
    _running = false;
    final wake = _retryWake;
    if (wake != null && !wake.isCompleted) wake.complete();
    _retryWake = null;
    _connection?.disconnect();
    _connection = null;
    _snapshotController.close();
    super.dispose();
  }
}
