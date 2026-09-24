/// Dart side of touch forwarding for CarPlay and Android Auto.
///
/// Mirrors the Kotlin host in `android/.../projection/ProjectionTouchBridge.kt`
/// and `ProjectionTouchStatus.kt`. The status-map key lists are one contract;
/// changing either side means changing both.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which OEM stack a touch is meant for. The wire names are the Kotlin enum's.
enum ProjectionStack {
  carplay('carplay'),
  androidAuto('android_auto');

  const ProjectionStack(this.wireName);

  final String wireName;
}

/// The `MotionEvent` actions this path carries.
///
/// CANCEL is here because Flutter reports one and the native policy rewrites it
/// into an UP. It must never be dropped on the Dart side instead: the OEM
/// CarPlay handler discards every action above 2 in silence, so a cancel that
/// goes nowhere leaves the phone holding a press that never lifts.
abstract final class ProjectionTouchAction {
  static const down = 0;
  static const up = 1;
  static const move = 2;
  static const cancel = 3;
  static const pointerDown = 5;
  static const pointerUp = 6;
}

/// One finger, in **buffer** coordinates.
@immutable
class ProjectionTouchPointer {
  const ProjectionTouchPointer({
    required this.id,
    required this.x,
    required this.y,
  });

  final int id;
  final double x;
  final double y;

  Map<String, Object?> toMap() => {'id': id, 'x': x, 'y': y};
}

/// What the native side did with a touch.
///
/// A refusal is not a failure. A touch on a letterbox bar, or a second finger
/// on CarPlay, is the path working as specified, so this is an ordinary result
/// rather than an exception.
@immutable
class ProjectionTouchResult {
  const ProjectionTouchResult({required this.sent, required this.dropReason});

  final bool sent;

  /// Machine code from the native policy, or null. Never shown raw.
  final String? dropReason;

  static const notSent = ProjectionTouchResult(sent: false, dropReason: null);

  factory ProjectionTouchResult.fromMap(Map<String, Object?> map) =>
      ProjectionTouchResult(
        sent: map['sent'] as bool? ?? false,
        dropReason: map['dropReason'] as String?,
      );
}

/// A per-axis scale and offset applied to a touch before it leaves, in buffer
/// pixels.
///
/// Mirrors `ProjectionTouchCalibration.kt`, which holds the reasoning: Android
/// Auto's own draw path and touch path disagree, none of the four values that
/// pull them apart is readable from this process, and every one of them is a
/// scale or an offset on one axis — so an affine correction absorbs whichever
/// is biting.
///
/// The scale turns about the centre of the buffer, which is what makes the two
/// knobs independent: fixing the offset does not change the scale, and fixing
/// the scale does not move the point already lined up.
@immutable
class ProjectionTouchCalibration {
  const ProjectionTouchCalibration({
    this.scaleX = 1.0,
    this.offsetX = 0.0,
    this.scaleY = 1.0,
    this.offsetY = 0.0,
  });

  final double scaleX;
  final double offsetX;
  final double scaleY;
  final double offsetY;

  /// Mirrors the native bounds. Kept here as well so the UI cannot offer a
  /// value the native side would silently bring back.
  static const minScale = 0.5;
  static const maxScale = 2.0;
  static const offsetLimit = 2000.0;

  static const identity = ProjectionTouchCalibration();

  /// The measured starting point per stack, mirroring the native
  /// `ProjectionTouchCalibration.defaultFor`.
  ///
  /// Measured on the car, 2026-08-13: Android Auto lands one keyboard row low
  /// at every card size, so it starts shifted up by 80 buffer pixels. CarPlay
  /// lands correctly and starts at the identity.
  ///
  /// It is the target of the reset, not the identity: on Android Auto the
  /// identity is the state that is known to be wrong.
  static ProjectionTouchCalibration defaultFor(ProjectionStack stack) =>
      switch (stack) {
        ProjectionStack.carplay => identity,
        ProjectionStack.androidAuto => androidAutoDefault,
      };

  static const androidAutoDefault = ProjectionTouchCalibration(offsetY: -80.0);

  bool get isIdentity =>
      scaleX == 1.0 && offsetX == 0.0 && scaleY == 1.0 && offsetY == 0.0;

  ProjectionTouchCalibration copyWith({
    double? scaleX,
    double? offsetX,
    double? scaleY,
    double? offsetY,
  }) => ProjectionTouchCalibration(
    scaleX: (scaleX ?? this.scaleX).clamp(minScale, maxScale),
    offsetX: (offsetX ?? this.offsetX).clamp(-offsetLimit, offsetLimit),
    scaleY: (scaleY ?? this.scaleY).clamp(minScale, maxScale),
    offsetY: (offsetY ?? this.offsetY).clamp(-offsetLimit, offsetLimit),
  );

  factory ProjectionTouchCalibration.fromMap(Map<String, Object?> map) {
    // Every field falls back to the identity, never to zero: a missing scale
    // read as 0.0 would collapse the axis onto its centre line.
    double read(String key, double fallback) =>
        (map[key] as num?)?.toDouble() ?? fallback;
    return ProjectionTouchCalibration(
      scaleX: read('scaleX', 1.0),
      offsetX: read('offsetX', 0.0),
      scaleY: read('scaleY', 1.0),
      offsetY: read('offsetY', 0.0),
    );
  }

  Map<String, Object?> toMap() => {
    'scaleX': scaleX,
    'offsetX': offsetX,
    'scaleY': scaleY,
    'offsetY': offsetY,
  };

  @override
  bool operator ==(Object other) =>
      other is ProjectionTouchCalibration &&
      other.scaleX == scaleX &&
      other.offsetX == offsetX &&
      other.scaleY == scaleY &&
      other.offsetY == offsetY;

  @override
  int get hashCode => Object.hash(scaleX, offsetX, scaleY, offsetY);

  @override
  String toString() =>
      'ProjectionTouchCalibration(x: $scaleX× ${offsetX}px, '
      'y: $scaleY× ${offsetY}px)';
}

/// One stack's touch state, mirrored from `ProjectionTouchStackStatus.toMap()`.
@immutable
class ProjectionTouchStackStatus {
  const ProjectionTouchStackStatus({
    required this.available,
    required this.bound,
    required this.bufferWidth,
    required this.bufferHeight,
    required this.gestureActive,
    required this.calibration,
    required this.sentCount,
    required this.droppedCount,
    required this.lastDropReason,
    required this.lastError,
  });

  /// The OEM session service resolves on this head unit.
  final bool available;
  final bool bound;
  final int bufferWidth;
  final int bufferHeight;
  final bool gestureActive;

  /// The correction the native side is applying. Identity until calibrated.
  final ProjectionTouchCalibration calibration;

  final int sentCount;
  final int droppedCount;
  final String? lastDropReason;
  final String? lastError;

  static const empty = ProjectionTouchStackStatus(
    available: false,
    bound: false,
    bufferWidth: 0,
    bufferHeight: 0,
    gestureActive: false,
    calibration: ProjectionTouchCalibration.identity,
    sentCount: 0,
    droppedCount: 0,
    lastDropReason: null,
    lastError: null,
  );

  /// Bound, and told what geometry the caller maps into. Both are required
  /// before a touch can leave: with no buffer there is nothing to clamp to.
  bool get canSend => bound && bufferWidth > 0 && bufferHeight > 0;

  factory ProjectionTouchStackStatus.fromMap(
    Map<String, Object?> map,
  ) => ProjectionTouchStackStatus(
    // A missing key means an older native build — default rather than throw.
    available: map['available'] as bool? ?? false,
    bound: map['bound'] as bool? ?? false,
    bufferWidth: map['bufferWidth'] as int? ?? 0,
    bufferHeight: map['bufferHeight'] as int? ?? 0,
    gestureActive: map['gestureActive'] as bool? ?? false,
    calibration: switch (map['calibration']) {
      final Map<Object?, Object?> raw => ProjectionTouchCalibration.fromMap(
        Map<String, Object?>.from(raw),
      ),
      _ => ProjectionTouchCalibration.identity,
    },
    sentCount: map['sentCount'] as int? ?? 0,
    droppedCount: map['droppedCount'] as int? ?? 0,
    lastDropReason: map['lastDropReason'] as String?,
    lastError: map['lastError'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is ProjectionTouchStackStatus &&
      other.available == available &&
      other.bound == bound &&
      other.bufferWidth == bufferWidth &&
      other.bufferHeight == bufferHeight &&
      other.gestureActive == gestureActive &&
      other.calibration == calibration &&
      other.sentCount == sentCount &&
      other.droppedCount == droppedCount &&
      other.lastDropReason == lastDropReason &&
      other.lastError == lastError;

  @override
  int get hashCode => Object.hash(
    available,
    bound,
    bufferWidth,
    bufferHeight,
    gestureActive,
    calibration,
    sentCount,
    droppedCount,
    lastDropReason,
    lastError,
  );

  @override
  String toString() =>
      'ProjectionTouchStackStatus(available: $available, bound: $bound, '
      'buffer: ${bufferWidth}x$bufferHeight, gestureActive: $gestureActive, '
      'sent: $sentCount, dropped: $droppedCount, '
      'lastDrop: $lastDropReason, lastError: $lastError)';
}

/// Both stacks together, which is what the native bridge publishes.
@immutable
class ProjectionTouchStatus {
  const ProjectionTouchStatus({
    required this.carplay,
    required this.androidAuto,
  });

  final ProjectionTouchStackStatus carplay;
  final ProjectionTouchStackStatus androidAuto;

  static const empty = ProjectionTouchStatus(
    carplay: ProjectionTouchStackStatus.empty,
    androidAuto: ProjectionTouchStackStatus.empty,
  );

  ProjectionTouchStackStatus of(ProjectionStack stack) => switch (stack) {
    ProjectionStack.carplay => carplay,
    ProjectionStack.androidAuto => androidAuto,
  };

  factory ProjectionTouchStatus.fromMap(Map<String, Object?> map) {
    ProjectionTouchStackStatus read(ProjectionStack stack) {
      final entry = map[stack.wireName];
      if (entry is! Map) return ProjectionTouchStackStatus.empty;
      return ProjectionTouchStackStatus.fromMap(
        Map<String, Object?>.from(entry),
      );
    }

    return ProjectionTouchStatus(
      carplay: read(ProjectionStack.carplay),
      androidAuto: read(ProjectionStack.androidAuto),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectionTouchStatus &&
      other.carplay == carplay &&
      other.androidAuto == androidAuto;

  @override
  int get hashCode => Object.hash(carplay, androidAuto);
}

/// Channel wrapper over `com.timhss.capyenergy/projection/touch`.
///
/// Subclassable and injectable, the same way [CarplayApi] is: screens take an
/// optional instance, which is how widget tests drive them without a channel.
/// On web and under `CAPY_MOCK_TELEMETRY` everything degrades to empty and
/// nothing is sent.
class ProjectionTouchApi {
  static const _channel = MethodChannel(
    'com.timhss.capyenergy/projection/touch',
  );
  static const _statusChannel = EventChannel(
    'com.timhss.capyenergy/projection/touch/status',
  );
  static const _forceMock = bool.fromEnvironment('CAPY_MOCK_TELEMETRY');

  static bool get _useMock => kIsWeb || _forceMock;

  /// Last status the native side successfully returned, so a channel failure
  /// degrades to the known truth instead of throwing away state.
  ProjectionTouchStatus _last = ProjectionTouchStatus.empty;

  Future<ProjectionTouchStatus> getStatus() => _invoke('getStatus');

  Future<ProjectionTouchStatus> bind(ProjectionStack stack) =>
      _invoke('bind', arguments: {'stack': stack.wireName});

  Future<ProjectionTouchStatus> unbind(ProjectionStack stack) =>
      _invoke('unbind', arguments: {'stack': stack.wireName});

  /// Declares the geometry this side maps into, which **must** be the geometry
  /// the renderer attached. Two different values put the touch and the picture
  /// in different places.
  Future<ProjectionTouchStatus> setBufferSize(
    ProjectionStack stack,
    int width,
    int height,
  ) => _invoke(
    'setBufferSize',
    arguments: {'stack': stack.wireName, 'width': width, 'height': height},
  );

  /// Sets the correction for one stack and saves it natively.
  ///
  /// It takes effect on the next touch, not on one already in flight: a
  /// gesture that started under one correction has to finish under it, or its
  /// DOWN and its UP would name two different places.
  Future<ProjectionTouchStatus> setCalibration(
    ProjectionStack stack,
    ProjectionTouchCalibration calibration,
  ) => _invoke(
    'setCalibration',
    arguments: {'stack': stack.wireName, ...calibration.toMap()},
  );

  /// Lifts every finger without unbinding.
  Future<ProjectionTouchStatus> releaseGestures() => _invoke('releaseGestures');

  /// Sends one touch, already mapped into buffer space.
  ///
  /// Never throws for a refused touch — see [ProjectionTouchResult]. A channel
  /// fault answers `sent: false` with the platform code as the reason, because
  /// a pointer stream must not become a source of unhandled errors.
  Future<ProjectionTouchResult> send({
    required ProjectionStack stack,
    required int action,
    required List<ProjectionTouchPointer> pointers,
    int actionIndex = 0,
  }) async {
    if (_useMock) return ProjectionTouchResult.notSent;
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('send', {
        'stack': stack.wireName,
        'action': action,
        'actionIndex': actionIndex,
        'pointers': [for (final p in pointers) p.toMap()],
      });
      if (map == null) return ProjectionTouchResult.notSent;
      return ProjectionTouchResult.fromMap(map);
    } on PlatformException catch (e) {
      return ProjectionTouchResult(sent: false, dropReason: e.code);
    } on MissingPluginException {
      return ProjectionTouchResult.notSent;
    }
  }

  Stream<ProjectionTouchStatus> statusStream() {
    if (_useMock) return const Stream.empty();
    return _statusChannel.receiveBroadcastStream().map(
      (event) => ProjectionTouchStatus.fromMap(
        Map<String, Object?>.from(event as Map),
      ),
    );
  }

  Future<ProjectionTouchStatus> _invoke(
    String method, {
    Map<String, Object?>? arguments,
  }) async {
    if (_useMock) return ProjectionTouchStatus.empty;
    try {
      final map = await _channel.invokeMapMethod<String, Object?>(
        method,
        arguments,
      );
      // A null reply is a broken channel, not an empty-but-valid result.
      return _last = map == null ? _last : ProjectionTouchStatus.fromMap(map);
    } on PlatformException {
      return _last;
    } on MissingPluginException {
      return _last;
    }
  }
}
