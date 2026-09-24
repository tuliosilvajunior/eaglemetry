import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';

import 'can_bridge_api.dart';
import 'can_bridge_models.dart';

typedef RoadcastStateFactory<T> = T Function(List<RoadcastSchemaEntry> entries);
typedef RoadcastSampleObserver<T> =
    void Function(T state, CanBridgeReading reading, int nowMillis);

/// Owns the hot path shared by the live trip and charging screens.
///
/// Roadcast already keeps the latest CAN frame in native RAM. This module pulls
/// that cache through one synchronous FFI read at 10 Hz, keeps connection and
/// retry policy in one place, and exposes separate repaint cadences for numbers
/// and charts. It never opens a platform channel and never touches Room.
class LiveRoadcastRuntime<T> {
  LiveRoadcastRuntime({
    required this.watchlist,
    required this.createState,
    required this.observeSample,
    this.onConnected,
    this.sampleInterval = const Duration(milliseconds: 100),
    this.chartInterval = const Duration(milliseconds: 100),
    this.retryInterval = const Duration(seconds: 10),
  });

  final List<String> watchlist;
  final RoadcastStateFactory<T> createState;
  final RoadcastSampleObserver<T> observeSample;
  final void Function(T state)? onConnected;
  final Duration sampleInterval;
  final Duration chartInterval;
  final Duration retryInterval;

  final ValueNotifier<int> fastTick = ValueNotifier<int>(0);
  final ValueNotifier<int> chartTick = ValueNotifier<int>(0);

  Timer? _sampleTimer;
  CanBridge? _bridge;
  T? _state;
  bool _running = false;
  bool _disposed = false;
  bool _connecting = false;
  DateTime? _lastAttempt;
  int _lastChartMillis = 0;
  int _sampleCount = 0;
  Object? _error;
  Map<String, int> _frameIds = const <String, int>{};

  T? get state => _state;
  bool get connecting => _connecting;
  bool get isAlive => _bridge?.isAlive ?? false;
  int get sampleCount => _sampleCount;
  int? get hz => _bridge?.hz;
  Duration? get pollAge => _bridge?.pollAge;
  Object? get error => _error;
  List<RoadcastSchemaEntry> get entries =>
      _bridge?.entries ?? const <RoadcastSchemaEntry>[];

  Map<String, int> get frameIds => _frameIds;

  Future<void> start() async {
    if (_disposed) return;
    _running = true;
    _sampleTimer ??= Timer.periodic(sampleInterval, (_) => _sample());
    if (_bridge == null) await _connect();
  }

  void stop() {
    _running = false;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _dropBridge();
    _notifyFast();
  }

  Future<void> reconnect() async {
    if (_disposed) return;
    _dropBridge();
    _lastAttempt = null;
    _error = null;
    _notifyFast();
    if (_running) await _connect();
  }

  Future<void> _connect() async {
    if (_disposed || !_running || _connecting) return;
    _connecting = true;
    _lastAttempt = DateTime.now();
    _notifyFast();
    try {
      final bridge = await CanBridge.connect(signals: watchlist);
      if (_disposed || !_running) {
        bridge?.dispose();
        return;
      }
      _bridge = bridge;
      _state = bridge == null ? null : createState(bridge.entries);
      _frameIds = bridge == null
          ? const <String, int>{}
          : {for (final entry in bridge.entries) entry.name: entry.canId};
      _sampleCount = 0;
      _lastChartMillis = 0;
      _error = null;
      final nextState = _state;
      if (nextState != null) onConnected?.call(nextState);
    } on Object catch (error) {
      _error = error;
      _dropBridge();
    } finally {
      _connecting = false;
      _notifyFast();
    }
  }

  void _sample() {
    if (_disposed || !_running) return;
    final bridge = _bridge;
    final currentState = _state;
    if (bridge == null || currentState == null) {
      _retryIfDue();
      return;
    }
    if (!bridge.isAlive) {
      _dropBridge();
      _notifyFast();
      _retryIfDue();
      return;
    }

    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    try {
      observeSample(currentState, bridge.sample(), nowMillis);
      _sampleCount++;
      _error = null;
      _notifyFast();
      if (nowMillis - _lastChartMillis >= chartInterval.inMilliseconds) {
        _lastChartMillis = nowMillis;
        chartTick.value++;
      }
    } on Object catch (error) {
      _error = error;
      _dropBridge();
      _notifyFast();
    }
  }

  void _retryIfDue() {
    if (_connecting) return;
    final lastAttempt = _lastAttempt;
    if (lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < retryInterval) {
      return;
    }
    unawaited(_connect());
  }

  void _dropBridge() {
    _bridge?.dispose();
    _bridge = null;
    _state = null;
    _frameIds = const <String, int>{};
  }

  void _notifyFast() {
    if (!_disposed) fastTick.value++;
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    fastTick.dispose();
    chartTick.dispose();
  }
}

/// Fixed-memory, time-bounded history for one live Roadcast signal.
///
/// Samples are kept in typed circular arrays. At 10 Hz the default 30-second
/// window reserves about 5 KiB per signal and never grows with session length.
/// Chart objects are allocated only when a chart repaints, already decimated to
/// the requested pixel-friendly point count.
class RollingSignalBuffer {
  RollingSignalBuffer({
    this.window = const Duration(seconds: 30),
    this.sampleRateHz = 10,
  }) : capacity = math.max(
         2,
         (window.inMicroseconds * sampleRateHz / Duration.microsecondsPerSecond)
                 .ceil() +
             1,
       ),
       _timestamps = Int64List(
         math.max(
           2,
           (window.inMicroseconds *
                       sampleRateHz /
                       Duration.microsecondsPerSecond)
                   .ceil() +
               1,
         ),
       ),
       _values = Float64List(
         math.max(
           2,
           (window.inMicroseconds *
                       sampleRateHz /
                       Duration.microsecondsPerSecond)
                   .ceil() +
               1,
         ),
       );

  final Duration window;
  final int sampleRateHz;
  final int capacity;
  final Int64List _timestamps;
  final Float64List _values;

  int _start = 0;
  int _length = 0;

  int get length => _length;
  bool get isEmpty => _length == 0;
  double? get latest => isEmpty ? null : _valueAt(_length - 1);

  void add(int timestampMillis, double? value) {
    if (value == null || !value.isFinite) return;
    _discardOlderThan(timestampMillis - window.inMilliseconds);

    final index = (_start + _length) % capacity;
    _timestamps[index] = timestampMillis;
    _values[index] = value;
    if (_length < capacity) {
      _length++;
    } else {
      _start = (_start + 1) % capacity;
    }
  }

  List<FlSpot> spots({int maxPoints = 240}) {
    if (_length == 0 || maxPoints <= 0) return const <FlSpot>[];
    final target = math.min(_length, maxPoints);
    final firstTimestamp = _timestampAt(0);
    if (target == 1) {
      return <FlSpot>[FlSpot(0, _valueAt(_length - 1))];
    }
    return <FlSpot>[
      for (var outputIndex = 0; outputIndex < target; outputIndex++)
        _spotAt(
          (outputIndex * (_length - 1) / (target - 1)).round(),
          firstTimestamp,
        ),
    ];
  }

  List<double> values({int maxPoints = 120}) {
    if (_length == 0 || maxPoints <= 0) return const <double>[];
    final target = math.min(_length, maxPoints);
    if (target == 1) return <double>[_valueAt(_length - 1)];
    return <double>[
      for (var outputIndex = 0; outputIndex < target; outputIndex++)
        _valueAt((outputIndex * (_length - 1) / (target - 1)).round()),
    ];
  }

  double get minX => 0;

  double get maxX {
    if (_length < 2) return 1;
    return (_timestampAt(_length - 1) - _timestampAt(0)) / 1000;
  }

  void clear() {
    _start = 0;
    _length = 0;
  }

  void _discardOlderThan(int cutoffMillis) {
    while (_length > 0 && _timestampAt(0) < cutoffMillis) {
      _start = (_start + 1) % capacity;
      _length--;
    }
  }

  int _timestampAt(int offset) => _timestamps[(_start + offset) % capacity];
  double _valueAt(int offset) => _values[(_start + offset) % capacity];

  FlSpot _spotAt(int offset, int firstTimestamp) =>
      FlSpot((_timestampAt(offset) - firstTimestamp) / 1000, _valueAt(offset));
}
