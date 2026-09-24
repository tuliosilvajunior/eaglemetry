import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_foreground_gate.dart';

/// One periodic read of the vehicle, with at most one read in flight.
///
/// Every surface that polls the bridge wrote the same three fields — a timer,
/// a running flag, and a re-entry guard — and several wrote only two of them.
/// A poll with no guard is not merely wasteful: two reads of the same query can
/// overlap, and the one that started first can answer last, so the screen shows
/// the older vehicle state and keeps it until the next tick.
///
/// The loop drops a tick that arrives during a read instead of queueing it. A
/// queued read would repeat a question whose answer is already on its way, and
/// the next tick asks it again anyway with fresher data.
class PollLoop {
  PollLoop({
    required this.interval,
    required Future<void> Function() read,
    this.onError,
    String? debugLabel,
    // An initializing formal would need a private named parameter, which Dart
    // does not allow.
    // ignore: prefer_initializing_formals
  }) : _read = read,
       debugLabel = debugLabel ?? 'PollLoop' {
    AppForegroundGate.instance.addListener(_onForegroundChanged);
  }

  /// The gap between the end of one tick and the next tick.
  final Duration interval;

  /// Receives an error thrown by a timer-driven read.
  ///
  /// A tick has no caller to return the error to, so an uncaught one becomes an
  /// unhandled asynchronous error in the app zone — once per tick, for as long
  /// as the fault lasts. When this is null the loop reports the error through
  /// [FlutterError.reportError] instead, which stays visible without ending the
  /// loop. A read that throws is a fault in the read, and it must not be quiet.
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Names the loop in assertion and error messages.
  final String debugLabel;

  final Future<void> Function() _read;

  Timer? _timer;
  bool _wanted = false;
  bool _reading = false;
  bool _disposed = false;

  /// True between [start] and [stop].
  ///
  /// An Activity pause disarms the timer but leaves this true, so a hidden
  /// tab that called [stop] and a started loop that the car put behind
  /// another screen stay distinct. Resume re-arms only the latter.
  bool get isRunning => _wanted;

  /// True while a read is in flight.
  bool get isReading => _reading;

  /// Starts the periodic read. A second call while running does nothing, so a
  /// screen that re-enters `initState` or a controller started by two surfaces
  /// cannot end up with two timers on one query.
  ///
  /// [immediate] runs the first read at once. Pass false when the caller has
  /// already read, or when the first read must wait for the phase of a clock
  /// the loop does not own.
  void start({bool immediate = true}) {
    assert(!_disposed, '$debugLabel: start after dispose');
    AppForegroundGate.instance.attachIfPossible();
    final alreadyWanted = _wanted;
    _wanted = true;
    if (alreadyWanted && _timer != null) return;
    _sync(immediate: immediate && !alreadyWanted);
  }

  void _tick() {
    unawaited(
      runNow().catchError((Object error, StackTrace stackTrace) {
        final handler = onError;
        if (handler != null) {
          handler(error, stackTrace);
          return;
        }
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'capy_energy',
            context: ErrorDescription('during a $debugLabel tick'),
          ),
        );
      }),
    );
  }

  /// Stops the periodic read. A read already in flight is not cancelled — it
  /// cannot be — but the loop schedules nothing more. [start] may follow.
  void stop() {
    _wanted = false;
    _disarm();
  }

  void _onForegroundChanged() {
    if (_disposed) return;
    if (!AppForegroundGate.instance.isForeground) {
      _disarm();
      return;
    }
    // An armed timer means a screen observer already handled this resume and
    // read. Observer order decides which of the two runs first, so without
    // this guard a screen that restarts its own loops issues two reads on
    // every resume — the second one saved only by the in-flight guard.
    if (_timer != null) return;
    _sync(immediate: true);
  }

  void _sync({required bool immediate}) {
    if (!_wanted || _disposed || !AppForegroundGate.instance.isForeground) {
      _disarm();
      return;
    }
    if (_timer != null) {
      if (immediate) _tick();
      return;
    }
    _timer = Timer.periodic(interval, (_) => _tick());
    if (immediate) _tick();
  }

  void _disarm() {
    _timer?.cancel();
    _timer = null;
  }

  /// Reads once, now, unless a read is already in flight.
  ///
  /// Returns when this call's read completes, or at once when it was dropped.
  /// The caller cannot tell the two apart on purpose: both mean "the freshest
  /// read that could be started, was".
  ///
  /// An error from the read reaches the caller that awaited it. The read owns
  /// the error policy, because only it knows whether a failed bridge call
  /// clears the screen or keeps the last good value. A tick has no such caller,
  /// so [onError] receives it instead. The guard is released either way, so one
  /// failure never stops the loop.
  Future<void> runNow() async {
    if (_reading || _disposed) return;
    _reading = true;
    try {
      await _read();
    } finally {
      _reading = false;
    }
  }

  /// Stops the loop and refuses further reads. Safe to call twice.
  void dispose() {
    AppForegroundGate.instance.removeListener(_onForegroundChanged);
    stop();
    _disposed = true;
  }
}

/// Several [PollLoop]s that start and stop together.
///
/// A screen with a data poll and a live-sample poll owns two loops with one
/// lifetime. The group exists so that lifetime is written once, and so a loop
/// added later cannot be forgotten in `dispose`.
class PollLoopGroup {
  PollLoopGroup(Iterable<PollLoop> loops) : _loops = List.unmodifiable(loops);

  final List<PollLoop> _loops;

  @visibleForTesting
  List<PollLoop> get loops => _loops;

  void start({bool immediate = true}) {
    for (final loop in _loops) {
      loop.start(immediate: immediate);
    }
  }

  void stop() {
    for (final loop in _loops) {
      loop.stop();
    }
  }

  void dispose() {
    for (final loop in _loops) {
      loop.dispose();
    }
  }
}
