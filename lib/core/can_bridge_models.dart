import 'dart:typed_data';

/// Immutable signal definition negotiated from the Roadcast daemon.
class RoadcastSchemaEntry {
  const RoadcastSchemaEntry({
    required this.stableId,
    required this.index,
    required this.invalidSignalIndex,
    required this.canId,
    required this.kind,
    required this.source,
    required this.width,
    required this.flags,
    required this.scale,
    required this.offset,
    required this.name,
    required this.unit,
  });

  final int stableId;
  final int index;
  final int? invalidSignalIndex;
  final int canId;
  final int kind;
  final int source;
  final int width;
  final int flags;
  final double scale;
  final double offset;
  final String name;
  final String unit;

  bool get isSigned => flags & 0x01 != 0;
  bool get isCalibrated => flags & 0x02 != 0;
}

/// Result of one batched native CAN cache read.
///
/// Lists are views over reusable native buffers and remain valid only until the
/// next read on the same session. Copy values that must outlive that call.
class CanBridgeReading {
  const CanBridgeReading({
    required this.values,
    required this.raws,
    required this.timestampsNs,
    required this.flags,
    this.firstObservedNs,
  });

  final List<double> values;
  final List<int> raws;
  final Int64List timestampsNs;
  final Uint8List flags;

  /// When the daemon first observed the frame this signal sits on, or null
  /// when the source does not report it.
  ///
  /// This is the only stamp that answers "has this ever arrived". Roadcast
  /// treats a frame as observed when its bytes first change after the startup
  /// baseline, so a zero here is silence since boot, and it is a different
  /// fact from [timestampsNs] standing still.
  final Int64List? firstObservedNs;

  int get length => values.length;

  double valueAt(int index) => values[index];

  int rawAt(int index) => raws[index];

  /// Timestamp of the last change of the **frame** this signal sits on.
  ///
  /// It is not the sampling tick, and it is not per signal: the daemon stamps
  /// the frame, so every signal on one frame shares this value. On a frame
  /// that carries an alive counter, a change accompanies each transmission and
  /// the stamp tracks arrival. On a frame without one, a constant payload
  /// leaves the stamp behind while the frame keeps arriving, which is why
  /// freshness read from here is a lower bound and never proof of silence.
  int timestampNsAt(int index) => timestampsNs[index];

  /// First observation of the frame, or 0 when it has never been observed.
  ///
  /// Returns null when the source did not report it, which the caller must
  /// treat as "unknown", not as "never".
  int? firstObservedNsAt(int index) => firstObservedNs?[index];

  bool isValidAt(int index) => flags[index] & 0x01 != 0;

  bool isCalibratedAt(int index) => flags[index] & 0x02 != 0;
}
