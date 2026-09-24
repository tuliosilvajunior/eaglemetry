/// Polling and history for the Signal Lab, kept out of the widgets.
///
/// The inspector runs at **10 Hz, not 60**. The pill on the live trip screen
/// samples at 60 Hz because it answers within a frame, but VHAL speed arrives
/// at 5 Hz and most CAN signals here change far slower than the screen can
/// draw. A higher rate would spend CPU on a table nobody can read that fast.
///
/// The scope keeps its own history at 1 Hz over 60 seconds, and **does not
/// smooth**. A diagnostic trace that has been filtered cannot answer the
/// question it was opened for: whether the bus itself is jittering.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'can_bridge_api.dart';
import 'can_bridge_models.dart';
import 'signal_lab.dart';

/// Where the lab gets its schema and samples.
///
/// An interface rather than a direct [CanBridge] so the screen can be built and
/// tested without a daemon. The live implementation is [RoadcastSignalSource].
abstract class SignalLabSource {
  List<RoadcastSchemaEntry> get entries;

  /// One batched read, or null when the bridge is not connected.
  CanBridgeReading? read();

  /// The clock the daemon stamps signal changes with.
  int nowNanos();

  bool get isAlive;

  Future<void> connect();

  void dispose();
}

/// The live source, over the Roadcast FFI bridge.
class RoadcastSignalSource implements SignalLabSource {
  RoadcastSignalSource();

  CanBridge? _bridge;
  final Stopwatch _clock = Stopwatch()..start();
  int _clockBaseNanos = 0;

  @override
  List<RoadcastSchemaEntry> get entries =>
      _bridge?.entries ?? const <RoadcastSchemaEntry>[];

  @override
  bool get isAlive => _bridge?.isAlive ?? false;

  @override
  Future<void> connect() async {
    if (_bridge != null) return;
    _bridge = await CanBridge.connect();
  }

  @override
  CanBridgeReading? read() {
    final bridge = _bridge;
    if (bridge == null || !bridge.isAlive) return null;
    final reading = bridge.sample();
    // Anchor the local clock on the newest change the daemon reported, so ages
    // are measured against the daemon's own clock rather than against wall
    // time. The two do not share an epoch, and mixing them would make every
    // signal look either ancient or from the future.
    var newest = 0;
    for (var i = 0; i < reading.length; i++) {
      final stamp = reading.timestampNsAt(i);
      if (stamp > newest) newest = stamp;
    }
    if (newest > _clockBaseNanos) {
      _clockBaseNanos = newest;
      _clock.reset();
    }
    return reading;
  }

  @override
  int nowNanos() => _clockBaseNanos + _clock.elapsedMicroseconds * 1000;

  @override
  void dispose() {
    _bridge?.dispose();
    _bridge = null;
  }
}

/// One traced signal's history, on the clock it was actually sampled against.
///
/// Points carry the time they were taken, not their ordinal. A counter assumes
/// the sampler kept its cadence; this one polls at 100 ms and adds a point when
/// a second has passed, so the true spacing is 1.0 to 1.1 s and it drifts.
/// Drawn against a counter, a scope reports even spacing it never had, and a
/// second the sampler missed entirely disappears instead of leaving a hole.
class ScopeTrace {
  ScopeTrace(
    this.name, {
    this.capacity = 60,
    this.window = const Duration(seconds: 60),
  });

  final String name;

  /// Hard cap on points held, so a fast sampler cannot grow this without end.
  final int capacity;

  /// How far back the trace keeps points. The window, not the count, is what
  /// bounds the trace in the way the reader sees it.
  final Duration window;

  final List<double?> _values = <double?>[];
  final List<int> _millis = <int>[];

  List<double?> get values => List<double?>.unmodifiable(_values);

  /// The time of each point, in milliseconds on the controller's clock.
  List<int> get millis => List<int>.unmodifiable(_millis);
  bool get isEmpty => _values.isEmpty;

  /// The newest point's time, or null when the trace is empty.
  int? get latestMillis => _millis.isEmpty ? null : _millis.last;

  /// Whether the points are raw counts rather than decoded values.
  ///
  /// Null until the first point that carries a number. The scope needs it to
  /// label the axis: a count drawn as if it were a measurement is the same
  /// defect as printing an assumed scale.
  bool? get isCount => _isCount;
  bool? _isCount;

  /// Adds one point. A null is kept as a null, never as a zero and never
  /// dropped: a gap in the trace is the record of a signal that stopped
  /// publishing, and closing it would draw a line the bus never sent.
  ///
  /// A signal that changes kind mid-trace — the daemon gained or lost a scale —
  /// starts over, for the reason [SignalSessionExtremes.observe] gives.
  void add(int atMillis, double? value, {bool? isCount}) {
    if (value != null && isCount != null && _isCount != isCount) {
      if (_isCount != null) {
        _values.clear();
        _millis.clear();
      }
      _isCount = isCount;
    }
    _millis.add(atMillis);
    _values.add(value);
    // Drop by age first, so what the trace holds is the window the reader was
    // promised rather than a count of points that may span more or less time.
    while (_millis.length > 1 &&
        atMillis - _millis.first > window.inMilliseconds) {
      _values.removeAt(0);
      _millis.removeAt(0);
    }
    while (_values.length > capacity) {
      _values.removeAt(0);
      _millis.removeAt(0);
    }
  }

  void clear() {
    _values.clear();
    _millis.clear();
    _isCount = null;
  }

  double? get minimum => _finite().fold<double?>(
    null,
    (acc, v) => acc == null || v < acc ? v : acc,
  );

  double? get maximum => _finite().fold<double?>(
    null,
    (acc, v) => acc == null || v > acc ? v : acc,
  );

  Iterable<double> _finite() =>
      _values.whereType<double>().where((v) => v.isFinite);
}

/// Drives the inspector table and the scope traces from one source.
class SignalLabController extends ChangeNotifier {
  SignalLabController({
    required this.source,
    this.inspectorInterval = const Duration(milliseconds: 100),
    this.scopeInterval = const Duration(seconds: 1),
    this.scopeWindow = const Duration(seconds: 60),
  });

  final SignalLabSource source;
  final Duration inspectorInterval;
  final Duration scopeInterval;
  final Duration scopeWindow;

  /// The most a scope can show at once. Four independent axes is already at the
  /// limit of what a reader can hold; more traces make a picture, not a
  /// measurement.
  static const int maxTraces = 4;

  final SignalSessionExtremes extremes = SignalSessionExtremes();

  Timer? _timer;
  bool _frozen = false;

  /// The scope's clock, monotonic and owned here so a test can step it.
  ///
  /// Wall time is the wrong clock for a scope: a time-zone or NTP correction
  /// would move points that were sampled correctly.
  final Stopwatch _clock = Stopwatch()..start();
  int? _lastScopeMillis;

  List<SignalRow> _rows = const <SignalRow>[];
  final List<ScopeTrace> _traces = <ScopeTrace>[];
  Object? _error;

  List<SignalRow> get rows => _rows;
  List<ScopeTrace> get traces => List<ScopeTrace>.unmodifiable(_traces);
  Object? get error => _error;
  bool get isAlive => source.isAlive;

  /// Whether the scope is holding its window still.
  ///
  /// Freezing stops the scope only. The inspector keeps updating, because its
  /// purpose is to say what the bus is doing now, and a frozen table that looks
  /// live is the one failure a diagnostic screen must not have.
  bool get frozen => _frozen;

  Future<void> start() async {
    _timer ??= Timer.periodic(inspectorInterval, (_) => _tick());
    try {
      await source.connect();
      _error = null;
    } catch (e) {
      _error = e;
    }
    notifyListeners();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void setFrozen(bool value) {
    if (_frozen == value) return;
    _frozen = value;
    notifyListeners();
  }

  bool isTraced(String name) => _traces.any((t) => t.name == name);

  /// Adds or removes a trace. Returns false when the scope is already full.
  bool toggleTrace(String name) {
    final index = _traces.indexWhere((t) => t.name == name);
    if (index >= 0) {
      _traces.removeAt(index);
      notifyListeners();
      return true;
    }
    if (_traces.length >= maxTraces) return false;
    _traces.add(
      ScopeTrace(
        name,
        // One spare point, because a sampler that runs a little late puts a
        // point at each end of the window rather than exactly the count the
        // ratio predicts. The window is the real bound; this only stops an
        // interval finer than the poll from growing the list without end.
        capacity: _scopeCapacity(),
        window: scopeWindow,
      ),
    );
    notifyListeners();
    return true;
  }

  /// Points a trace may hold at once.
  ///
  /// An interval of zero means "every poll", which is what a test uses to step
  /// the controller by hand. There is no ratio to take then, so the cap falls
  /// back to one point per millisecond of the window — far more than any real
  /// poll produces, and still bounded.
  int _scopeCapacity() {
    final interval = scopeInterval.inMilliseconds;
    final slots = interval <= 0
        ? scopeWindow.inMilliseconds
        : scopeWindow.inMilliseconds ~/ interval;
    return slots < 1 ? 2 : slots + 1;
  }

  void clearTraces() {
    _traces.clear();
    notifyListeners();
  }

  void resetSession() {
    extremes.clear();
    for (final trace in _traces) {
      trace.clear();
    }
    notifyListeners();
  }

  /// One poll. Exposed so a test can step the controller without a timer.
  @visibleForTesting
  void tick() => _tick();

  void _tick() {
    final reading = source.read();
    if (reading == null) {
      _rows = const <SignalRow>[];
      // A bridge that is not answering is still a fact about the window, and
      // the scope has to record it as one. Skipping the point instead would
      // join the line across the outage and draw a segment nothing sent.
      _sampleScope(const <String, SignalRow>{});
      notifyListeners();
      return;
    }

    _rows = buildSignalRows(
      entries: source.entries,
      reading: reading,
      nowNanos: source.nowNanos(),
      extremes: extremes,
    );

    _sampleScope(<String, SignalRow>{for (final row in _rows) row.name: row});
    notifyListeners();
  }

  void _sampleScope(Map<String, SignalRow> byName) {
    if (_frozen || _traces.isEmpty) return;
    final at = _scopeDue();
    if (at == null) return;
    for (final trace in _traces) {
      final row = byName[trace.name];
      // The count when there is no scale, so the two uncalibrated power
      // signals can be watched at all. `SignalRow.plotsRawCount` carries
      // which of the two the point is, and the scope labels its axis from it.
      trace.add(at, row?.plottable, isCount: row?.plotsRawCount);
    }
  }

  /// The time to stamp this point with, or null when the interval has not run
  /// out yet.
  ///
  /// The stamp is the real elapsed time, not the deadline it was due at. The
  /// poll is ten times finer than the interval, so a point lands up to one poll
  /// late, and rounding that away would let the drift accumulate invisibly
  /// while the axis kept claiming even spacing.
  int? _scopeDue() {
    final now = _clock.elapsedMilliseconds;
    final last = _lastScopeMillis;
    if (last != null && now - last < scopeInterval.inMilliseconds) return null;
    _lastScopeMillis = now;
    return now;
  }

  @override
  void dispose() {
    stop();
    source.dispose();
    super.dispose();
  }
}
