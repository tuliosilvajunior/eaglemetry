/// Dart side of the CarPlay card.
///
/// Mirrors the Kotlin host in `android/.../carplay/CarplayBridge.kt` and
/// `CarplayStatus.kt`. The two status-map key lists are one contract; changing
/// either side means changing both tests.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Snapshot of the native CarPlay host state, mirrored exactly from
/// `CarplayStatus.toMap()`.
@immutable
class CarplayStatus {
  const CarplayStatus({
    required this.available,
    required this.bound,
    required this.attached,
    required this.activityResumed,
    required this.dartActive,
    required this.textureId,
    required this.bufferWidth,
    required this.bufferHeight,
    required this.attachCount,
    required this.lastError,
  });

  /// The OEM CarPlay app exposes its exfeature service on this head unit.
  final bool available;
  final bool bound;

  /// We currently own the OEM renderer's main surface.
  ///
  /// True does **not** mean video is arriving: the decoder is started by the
  /// native CarPlay stack, not by us, so an attached surface with no session
  /// draws nothing. The UI must say so rather
  /// than claim a connection it cannot observe.
  final bool attached;

  final bool activityResumed;
  final bool dartActive;
  final int? textureId;
  final int bufferWidth;
  final int bufferHeight;
  final int attachCount;

  /// Machine code from the native host, or null. Never shown raw.
  final String? lastError;

  static const empty = CarplayStatus(
    available: false,
    bound: false,
    attached: false,
    activityResumed: false,
    dartActive: false,
    textureId: null,
    bufferWidth: 0,
    bufferHeight: 0,
    attachCount: 0,
    lastError: null,
  );

  /// Aspect of the render buffer.
  ///
  /// Falls back to 16:9 when the buffer has not been created yet — `AspectRatio`
  /// throws on a non-finite ratio, and a zero-sized buffer is a legitimate
  /// transient state during activation.
  double get bufferAspect => (bufferWidth > 0 && bufferHeight > 0)
      ? bufferWidth / bufferHeight
      : 16 / 9;

  /// The texture exists and we own the renderer, so a `Texture` can be built.
  bool get canRender => attached && textureId != null;

  factory CarplayStatus.fromMap(Map<String, Object?> map) {
    return CarplayStatus(
      // A missing key means an older native build — default rather than throw.
      available: map['available'] as bool? ?? false,
      bound: map['bound'] as bool? ?? false,
      attached: map['attached'] as bool? ?? false,
      activityResumed: map['activityResumed'] as bool? ?? false,
      dartActive: map['dartActive'] as bool? ?? false,
      textureId: (map['textureId'] as num?)?.toInt(),
      bufferWidth: map['bufferWidth'] as int? ?? 0,
      bufferHeight: map['bufferHeight'] as int? ?? 0,
      attachCount: map['attachCount'] as int? ?? 0,
      lastError: map['lastError'] as String?,
    );
  }

  CarplayStatus copyWith({
    bool? available,
    bool? bound,
    bool? attached,
    bool? activityResumed,
    bool? dartActive,
    int? textureId,
    bool clearTextureId = false,
    int? bufferWidth,
    int? bufferHeight,
    int? attachCount,
    String? lastError,
    bool clearLastError = false,
  }) {
    return CarplayStatus(
      available: available ?? this.available,
      bound: bound ?? this.bound,
      attached: attached ?? this.attached,
      activityResumed: activityResumed ?? this.activityResumed,
      dartActive: dartActive ?? this.dartActive,
      textureId: clearTextureId ? null : (textureId ?? this.textureId),
      bufferWidth: bufferWidth ?? this.bufferWidth,
      bufferHeight: bufferHeight ?? this.bufferHeight,
      attachCount: attachCount ?? this.attachCount,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CarplayStatus &&
        other.available == available &&
        other.bound == bound &&
        other.attached == attached &&
        other.activityResumed == activityResumed &&
        other.dartActive == dartActive &&
        other.textureId == textureId &&
        other.bufferWidth == bufferWidth &&
        other.bufferHeight == bufferHeight &&
        other.attachCount == attachCount &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hash(
    available,
    bound,
    attached,
    activityResumed,
    dartActive,
    textureId,
    bufferWidth,
    bufferHeight,
    attachCount,
    lastError,
  );

  @override
  String toString() =>
      'CarplayStatus(available: $available, bound: $bound, '
      'attached: $attached, textureId: $textureId, buffer: ${bufferWidth}x'
      '$bufferHeight, attachCount: $attachCount, lastError: $lastError)';
}

/// Channel wrapper over `com.timhss.capyenergy/carplay`.
///
/// Subclassable and injectable: screens take an optional [CarplayApi]
/// constructor parameter, which is how widget tests drive them. All four
/// methods return the fresh status map, so the caller never needs a follow-up
/// read. On web and under `CAPY_MOCK_TELEMETRY` everything degrades to
/// [CarplayStatus.empty] without touching the channel.
class CarplayApi {
  static const _channel = MethodChannel('com.timhss.capyenergy/carplay');
  static const _statusChannel = EventChannel(
    'com.timhss.capyenergy/carplay/status',
  );
  static const _forceMock = bool.fromEnvironment('CAPY_MOCK_TELEMETRY');

  static bool get _useMock => kIsWeb || _forceMock;

  /// Last status the native side successfully returned, so a channel failure
  /// degrades to the known truth with [CarplayStatus.lastError] set instead of
  /// throwing away state the UI could still show.
  CarplayStatus _last = CarplayStatus.empty;

  Future<CarplayStatus> getStatus() => _invoke('getStatus');

  Future<CarplayStatus> activate({int? width, int? height}) =>
      _invoke('activate', arguments: {'width': width, 'height': height});

  Future<CarplayStatus> deactivate() => _invoke('deactivate');

  Future<CarplayStatus> refresh() => _invoke('refresh');

  Stream<CarplayStatus> statusStream() {
    if (_useMock) return const Stream.empty();
    // The event payload is exactly the status map from `CarplayStatus.toMap()`.
    return _statusChannel.receiveBroadcastStream().map(
      (event) => CarplayStatus.fromMap(Map<String, Object?>.from(event as Map)),
    );
  }

  Future<CarplayStatus> _invoke(
    String method, {
    Map<String, Object?>? arguments,
  }) async {
    if (_useMock) return CarplayStatus.empty;
    try {
      final map = await _channel.invokeMapMethod<String, Object?>(
        method,
        arguments,
      );
      // A null reply is a broken channel, not an empty-but-valid result.
      // Carry the previous state so the UI keeps showing what it knew.
      return _last = map == null
          ? _last.copyWith(lastError: 'EMPTY_REPLY')
          : CarplayStatus.fromMap(map);
    } on PlatformException catch (e) {
      return _last = _last.copyWith(lastError: e.code);
    }
  }
}
