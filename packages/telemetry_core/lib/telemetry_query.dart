import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'poll_loop.dart';

/// Turns a bridge failure into the line a screen shows.
///
/// Three screens wrote this, character for character, and a fourth wrote it
/// twice. The code matters more than the message when a read fails on the car,
/// so it stays in front of it.
String describeBridgeError(Object error) {
  if (error is PlatformException) {
    return '${error.code}: ${error.message ?? 'bridge error'}';
  }
  return error.toString();
}

/// What a screen knows about one read.
///
/// The three fields a screen used to hold separately — value, loading, error —
/// have combinations that cannot happen and combinations that carry meaning.
/// `loading` with no value is a first read; `loading` with a value is a
/// refresh; an error with a value is a refresh that failed over data the reader
/// is still looking at. Keeping them apart let a screen paint the spinner and
/// the error at once, and left every screen to decide the rules again.
@immutable
class Loadable<T> {
  const Loadable._(this.value, this.error, this.isLoading);

  /// Nothing read yet.
  const Loadable.loading() : this._(null, null, true);

  /// A value, from a read that succeeded.
  const Loadable.ready(T value) : this._(value, null, false);

  /// A failure. [value] is the last good one, when the screen keeps it.
  const Loadable.failed(Object error, {T? value}) : this._(value, error, false);

  /// The last good value, or null when no read has succeeded.
  final T? value;

  /// The error from the last read, or null when it succeeded.
  final Object? error;

  /// A read is in flight.
  final bool isLoading;

  /// True while the screen has nothing to draw and a read is running. This is
  /// the only state that deserves a full-screen spinner; a refresh over an
  /// existing value does not.
  bool get isFirstLoad => isLoading && value == null;

  /// True when the read failed and nothing is left to show.
  bool get isEmptyFailure => error != null && value == null;

  /// The failure as a screen line, or null.
  String? get errorMessage {
    final failure = error;
    return failure == null ? null : describeBridgeError(failure);
  }

  /// The same state with a read in flight. The value stays, so a refresh does
  /// not blank the screen.
  Loadable<T> loading({bool keepValue = true}) =>
      Loadable<T>._(keepValue ? value : null, null, true);

  @override
  bool operator ==(Object other) =>
      other is Loadable<T> &&
      other.value == value &&
      other.error == error &&
      other.isLoading == isLoading;

  @override
  int get hashCode => Object.hash(value, error, isLoading);

  @override
  String toString() =>
      'Loadable(value: $value, error: $error, isLoading: $isLoading)';
}

/// One question asked of the vehicle, with its answer and its cadence.
///
/// Every list and detail screen wrote the same object by hand: a poll timer, a
/// re-entry guard, a request counter, and three fields for the answer. The
/// counter is the part most of them left out, and it is the one that matters —
/// without it, the answer to a question the reader has already replaced can
/// land on the screen and stay there.
///
/// [read] is a closure, so a screen that changes what it is asking — a
/// different range, a different session — changes its own state and calls
/// [refresh]. The answer to the previous question is then dropped on arrival.
class TelemetryQuery<T> extends ChangeNotifier {
  TelemetryQuery({
    required Future<T> Function() read,
    Duration? interval,
    String? debugLabel,
    this.refreshOn,
    // An initializing formal would need a private named parameter, which Dart
    // does not allow.
    // ignore: prefer_initializing_formals
  }) : _read = read {
    _loop = PollLoop(
      interval: interval ?? const Duration(seconds: 5),
      read: _runRead,
      debugLabel: debugLabel ?? 'TelemetryQuery',
      // The read never throws: [_runRead] turns a failure into state.
      onError: (_, _) {},
    );
  }

  /// Reads again whenever this fires.
  ///
  /// The car says when a session was written, so a list does not have to keep
  /// asking whether one was. The loop stays as the fallback: a missed event
  /// would otherwise leave a list stale until the screen was reopened, and an
  /// event stream that never connects is indistinguishable from a car that is
  /// simply not writing.
  final Stream<void>? refreshOn;

  final Future<T> Function() _read;
  late final PollLoop _loop;
  StreamSubscription<void>? _pushes;

  Loadable<T> _state = Loadable<T>.loading();
  int _request = 0;
  bool _disposed = false;

  Loadable<T> get state => _state;

  /// The last good value, or null.
  T? get value => _state.value;

  /// Starts the periodic read, beginning with one now.
  void start() {
    _listenForPushes();
    _loop.start();
  }

  /// Starts the periodic read without one now. Use it when the caller has
  /// already asked for the first read.
  void startLater() {
    _listenForPushes();
    _loop.start(immediate: false);
  }

  void stop() {
    unawaited(_pushes?.cancel());
    _pushes = null;
    _loop.stop();
  }

  /// Pauses or resumes the tick. The push keeps working either way.
  ///
  /// That is the point of having both: a list with nothing live has nothing a
  /// tick could find, and waits for the car to say a session was written. A
  /// list with an open row polls, because that row's newest SOC and odometer
  /// come from frames and no session write announces them.
  void setPolling(bool enabled) {
    if (enabled) {
      _loop.start(immediate: false);
    } else {
      _loop.stop();
    }
  }

  void _listenForPushes() {
    final stream = refreshOn;
    if (stream == null || _pushes != null) return;
    _pushes = stream.listen(
      (_) => unawaited(refresh()),
      // A broken push is not a broken screen: the loop still reads. Clearing
      // the subscription lets a later start try again.
      onError: (Object _) {},
    );
  }

  /// Reads once, unless a read is in flight.
  ///
  /// [showLoading] paints the spinner over the current value. Leave it false
  /// for a background tick, which must not make a screen look busy.
  Future<void> refresh({bool showLoading = false}) {
    if (showLoading && !_state.isLoading) {
      _emit(_state.loading());
    }
    return _loop.runNow();
  }

  /// Asks a new question: drops the current answer and reads at once.
  ///
  /// The old value is not a stale version of the new answer; it is the answer
  /// to something else. Keeping it on screen under the new label is the one
  /// failure a screen that switches range or session must not have.
  ///
  /// This deliberately skips the loop's guard. A read already in flight is the
  /// previous question, so joining it would answer the wrong thing, and waiting
  /// for it would leave the screen loading with nothing on its way. The request
  /// counter is what makes the overlap safe: whichever lands first, only this
  /// read's answer is kept.
  Future<void> ask() {
    _request++;
    _emit(Loadable<T>.loading());
    return _runRead();
  }

  /// Records an answer the screen already holds, without reading again.
  ///
  /// A control that writes to the vehicle is given a read-back, and that
  /// read-back is a fresher answer to the same question this query asks.
  /// Without somewhere to put it, a screen keeps the written value in a field
  /// beside the query and then has to decide, at every use, which of the two is
  /// current. That is the pair this exists to avoid.
  ///
  /// The request counter is bumped, so a read already in flight cannot land on
  /// top of the read-back. It does not order two writes against each other —
  /// whichever calls this last wins — so a caller that can have two writes
  /// outstanding still needs its own guard.
  void put(T value) {
    _request++;
    _emit(Loadable<T>.ready(value));
  }

  Future<void> _runRead() async {
    final request = ++_request;
    try {
      final result = await _read();
      if (request != _request) return;
      _emit(Loadable<T>.ready(result));
    } catch (error) {
      if (request != _request) return;
      // The last good value survives a failed read. The screen decides whether
      // to show it beside the error; throwing it away here would remove that
      // choice from the only place that can make it.
      _emit(Loadable<T>.failed(error, value: _state.value));
    }
  }

  void _emit(Loadable<T> next) {
    if (_disposed || next == _state) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_pushes?.cancel());
    _pushes = null;
    _loop.dispose();
    super.dispose();
  }
}
