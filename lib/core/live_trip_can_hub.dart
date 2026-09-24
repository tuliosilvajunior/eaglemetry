import 'can_bridge_models.dart';
import 'live_roadcast_runtime.dart';
import 'live_trip_can.dart';

/// One CAN sample after the hub has already folded it into [state].
typedef LiveTripCanListener =
    void Function(LiveTripCanState state, int nowMillis);

/// One [LiveRoadcastRuntime] shared by the shell footer cards.
///
/// Incline and smoothness used to each open a 60 Hz FFI client. The watchlist
/// is the same, so one client and one sample path is enough. Holders
/// [acquire] and [release] so the timer runs only while someone can see it.
class LiveTripCanHub {
  LiveTripCanHub({LiveRoadcastRuntime<LiveTripCanState>? runtime})
    : _ownsRuntime = runtime == null {
    _runtime =
        runtime ??
        LiveRoadcastRuntime<LiveTripCanState>(
          watchlist: LiveTripCanNames.watchlist,
          createState: (entries) =>
              LiveTripCanState(entries: entries, retainActivityHistory: false),
          observeSample: _onSample,
        );
  }

  final bool _ownsRuntime;
  late final LiveRoadcastRuntime<LiveTripCanState> _runtime;
  final List<LiveTripCanListener> _listeners = <LiveTripCanListener>[];
  int _holders = 0;
  bool _disposed = false;

  /// How many cards currently want samples.
  int get holders => _holders;

  void addListener(LiveTripCanListener listener) {
    if (_disposed) return;
    _listeners.add(listener);
  }

  void removeListener(LiveTripCanListener listener) {
    _listeners.remove(listener);
  }

  /// Starts the 60 Hz client on the first holder.
  Future<void> acquire() async {
    if (_disposed) return;
    _holders++;
    if (_holders == 1) await _runtime.start();
  }

  /// Stops the client when the last holder leaves.
  void release() {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) _runtime.stop();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
    _holders = 0;
    if (_ownsRuntime) {
      _runtime.dispose();
    } else {
      _runtime.stop();
    }
  }

  void _onSample(
    LiveTripCanState state,
    CanBridgeReading reading,
    int nowMillis,
  ) {
    state.observe(reading, nowMillis);
    _dispatch(state, nowMillis);
  }

  /// Test seam: fan a ready state out without touching FFI.
  void debugDispatch(LiveTripCanState state, int nowMillis) {
    _dispatch(state, nowMillis);
  }

  void _dispatch(LiveTripCanState state, int nowMillis) {
    final listeners = List<LiveTripCanListener>.of(_listeners);
    for (final listener in listeners) {
      listener(state, nowMillis);
    }
  }
}
