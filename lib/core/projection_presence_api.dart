/// Which phone is connected.
///
/// Mirrors the Kotlin monitor in
/// `android/.../projection/ProjectionPresenceMonitor.kt` and
/// `ProjectionPresenceSnapshot.kt`. The map key list is one contract; changing
/// either side means changing both tests.
///
/// This is deliberately **not** part of `CarplayApi`. Presence is a different
/// question with a different source: `CarplayStatus` describes this app's own
/// render surface, and a black card with a live attach looks exactly like a
/// black card with no phone.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether one protocol has a live phone session.
///
/// [unknown] is not [disconnected]. It means no getter answered and no edge has
/// arrived — the OEM app is absent from this head unit, or a binder call
/// failed. The app must not say "no phone connected" when what it means is
/// "this app does not know".
enum PresenceState {
  connected,
  disconnected,
  unknown;

  static PresenceState fromWire(Object? value) {
    switch (value) {
      case 'connected':
        return PresenceState.connected;
      case 'disconnected':
        return PresenceState.disconnected;
      // An unrecognized name is a native build this one does not understand,
      // which is the definition of not knowing.
      default:
        return PresenceState.unknown;
    }
  }
}

/// Snapshot of both projection stacks, mirrored from
/// `ProjectionPresenceSnapshot.toMap()`.
@immutable
class ProjectionPresence {
  const ProjectionPresence({
    required this.carplay,
    required this.androidAuto,
    required this.carplayAvailable,
    required this.androidAutoAvailable,
    required this.carplayEdgeAt,
    required this.androidAutoEdgeAt,
  });

  final PresenceState carplay;
  final PresenceState androidAuto;

  /// The OEM app declares its presence service on this head unit.
  final bool carplayAvailable;
  final bool androidAutoAvailable;

  /// Monotonic device uptime of the last state change, used only to order two
  /// connect edges against each other. Not wall-clock time. Never shown.
  final int? carplayEdgeAt;
  final int? androidAutoEdgeAt;

  static const unknown = ProjectionPresence(
    carplay: PresenceState.unknown,
    androidAuto: PresenceState.unknown,
    carplayAvailable: false,
    androidAutoAvailable: false,
    carplayEdgeAt: null,
    androidAutoEdgeAt: null,
  );

  factory ProjectionPresence.fromMap(Map<String, Object?> map) {
    return ProjectionPresence(
      carplay: PresenceState.fromWire(map['carplay']),
      androidAuto: PresenceState.fromWire(map['androidAuto']),
      carplayAvailable: map['carplayAvailable'] as bool? ?? false,
      androidAutoAvailable: map['androidAutoAvailable'] as bool? ?? false,
      carplayEdgeAt: (map['carplayEdgeAt'] as num?)?.toInt(),
      androidAutoEdgeAt: (map['androidAutoEdgeAt'] as num?)?.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectionPresence &&
      other.carplay == carplay &&
      other.androidAuto == androidAuto &&
      other.carplayAvailable == carplayAvailable &&
      other.androidAutoAvailable == androidAutoAvailable &&
      other.carplayEdgeAt == carplayEdgeAt &&
      other.androidAutoEdgeAt == androidAutoEdgeAt;

  @override
  int get hashCode => Object.hash(
    carplay,
    androidAuto,
    carplayAvailable,
    androidAutoAvailable,
    carplayEdgeAt,
    androidAutoEdgeAt,
  );

  @override
  String toString() =>
      'ProjectionPresence(carplay: ${carplay.name}, '
      'androidAuto: ${androidAuto.name})';
}

/// Which projection tabs the shell shows.
@immutable
class ProjectionTabs {
  const ProjectionTabs({required this.carplay, required this.androidAuto});

  final bool carplay;
  final bool androidAuto;

  static const none = ProjectionTabs(carplay: false, androidAuto: false);

  @override
  bool operator ==(Object other) =>
      other is ProjectionTabs &&
      other.carplay == carplay &&
      other.androidAuto == androidAuto;

  @override
  int get hashCode => Object.hash(carplay, androidAuto);

  @override
  String toString() =>
      'ProjectionTabs(carplay: $carplay, '
      'androidAuto: $androidAuto)';
}

/// The projection tab rule, as a pure function.
///
/// A beta switch that is off removes its protocol before anything else is
/// considered: nothing is probed for it, so it cannot be present.
///
/// `bound` is the fallback, not the rule. It only says the OEM service is
/// reachable, and that service is installed on every one of these head units,
/// so on its own it shows the tab whether or not a phone is there. It is used
/// only where presence is [PresenceState.unknown], because hiding a card that
/// would have worked is worse than showing one that stays black — and the black
/// card already says what it is.
ProjectionTabs resolveProjectionTabs({
  required ProjectionPresence presence,
  required bool carplayEnabled,
  required bool androidAutoEnabled,
  required bool carplayBound,
  required bool androidAutoBound,
}) {
  final carplay = carplayEnabled
      ? presence.carplay
      : PresenceState.disconnected;
  final androidAuto = androidAutoEnabled
      ? presence.androidAuto
      : PresenceState.disconnected;

  // Both connected. The head unit arbitrates a single projection session, so
  // this should be transient; the newer edge is the one the driver just made.
  if (carplay == PresenceState.connected &&
      androidAuto == PresenceState.connected) {
    final cpAt = presence.carplayEdgeAt;
    final aaAt = presence.androidAutoEdgeAt;
    if (cpAt == null || aaAt == null || cpAt == aaAt) {
      // Nothing to order them by. Showing both is the honest answer: at most
      // one will render, and hiding the wrong one leaves no way back.
      return const ProjectionTabs(carplay: true, androidAuto: true);
    }
    return ProjectionTabs(carplay: cpAt > aaAt, androidAuto: aaAt > cpAt);
  }

  // Exactly one connected. It wins outright — an unknown protocol must not
  // put a second projection tab beside a phone we can see.
  if (carplay == PresenceState.connected) return _carplayOnly;
  if (androidAuto == PresenceState.connected) return _androidAutoOnly;

  // Neither is connected. Only an unknown can still show a tab, and only on
  // the old `bound` evidence.
  return ProjectionTabs(
    carplay: carplay == PresenceState.unknown && carplayBound,
    androidAuto: androidAuto == PresenceState.unknown && androidAutoBound,
  );
}

const _carplayOnly = ProjectionTabs(carplay: true, androidAuto: false);
const _androidAutoOnly = ProjectionTabs(carplay: false, androidAuto: true);

/// Channel wrapper over `com.timhss.capyenergy/projection`.
///
/// Injectable the same way [CarplayApi] is, which is how widget tests drive the
/// shell. On web and under `CAPY_MOCK_TELEMETRY` it degrades to
/// [ProjectionPresence.unknown] without touching the channel, so the shell
/// falls back to the `bound` rule there.
class ProjectionPresenceApi {
  static const _channel = MethodChannel('com.timhss.capyenergy/projection');
  static const _presenceChannel = EventChannel(
    'com.timhss.capyenergy/projection/presence',
  );
  static const _forceMock = bool.fromEnvironment('CAPY_MOCK_TELEMETRY');

  static bool get _useMock => kIsWeb || _forceMock;

  ProjectionPresence _last = ProjectionPresence.unknown;

  Future<ProjectionPresence> getPresence() => _invoke('getPresence');

  Future<ProjectionPresence> refresh() => _invoke('refresh');

  Stream<ProjectionPresence> presenceStream() {
    if (_useMock) return const Stream.empty();
    return _presenceChannel.receiveBroadcastStream().map(
      (event) =>
          ProjectionPresence.fromMap(Map<String, Object?>.from(event as Map)),
    );
  }

  Future<ProjectionPresence> _invoke(String method) async {
    if (_useMock) return ProjectionPresence.unknown;
    try {
      final map = await _channel.invokeMapMethod<String, Object?>(method);
      // A null reply is a broken channel. Keep what we knew rather than
      // reporting a disconnection the car never sent.
      return _last = map == null ? _last : ProjectionPresence.fromMap(map);
    } on PlatformException {
      return _last;
    } on MissingPluginException {
      // An older native build with no projection channel. Unknown, so the
      // shell keeps using `bound`.
      return _last;
    }
  }
}
