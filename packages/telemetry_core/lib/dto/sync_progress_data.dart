part of 'telemetry_dto.dart';

/// Progress state of local records versus the cloud, calculated from dirty vs clean counts.
///
/// A record is 'clean' when confirmed synced to the cloud (`dirty == 0`),
/// 'dirty' when waiting to be uploaded (`dirty == 1` and clock known/ready),
/// and 'pending' when waiting on real-time clock authority (`dirty == 1` and `timeState == 'pending'`).
@immutable
class SyncProgressData {
  const SyncProgressData({
    required this.totalCount,
    required this.dirtyCount,
    this.pendingCount = 0,
  }) : assert(totalCount >= 0, 'totalCount cannot be negative'),
       assert(dirtyCount >= 0, 'dirtyCount cannot be negative'),
       assert(pendingCount >= 0, 'pendingCount cannot be negative');

  /// Zero progress constant when no data exists.
  static const zero = SyncProgressData(
    totalCount: 0,
    dirtyCount: 0,
    pendingCount: 0,
  );

  /// Total count of local telemetry records across tracked tables.
  final int totalCount;

  /// Count of local records with `dirty = 1` waiting for cloud upload.
  final int dirtyCount;

  /// Count of local records waiting for real-time clock authority before they can be uploaded.
  final int pendingCount;

  /// Count of records already uploaded/synced (`dirty = 0`).
  int get cleanCount =>
      (totalCount - dirtyCount - pendingCount).clamp(0, totalCount);

  /// Fraction between 0.0 and 1.0 representing sync progress.
  /// When totalCount is 0, defaults to 1.0 (everything up to date).
  double get ratio =>
      totalCount == 0 ? 1.0 : (cleanCount / totalCount).clamp(0.0, 1.0);

  /// Progress expressed as a percentage integer (0 to 100).
  int get percentage => (ratio * 100).round();

  /// True when no records are waiting for upload or time authority.
  bool get isUpToDate => dirtyCount == 0 && pendingCount == 0;

  Map<String, Object?> toMap() => {
    'totalCount': totalCount,
    'dirtyCount': dirtyCount,
    'pendingCount': pendingCount,
  };

  static SyncProgressData fromMap(Map<String, Object?>? map) {
    if (map == null) return zero;
    final total = (map['totalCount'] as num?)?.toInt() ?? 0;
    final dirty = (map['dirtyCount'] as num?)?.toInt() ?? 0;
    final pending = (map['pendingCount'] as num?)?.toInt() ?? 0;
    return SyncProgressData(
      totalCount: math.max(0, total),
      dirtyCount: math.max(0, dirty),
      pendingCount: math.max(0, pending),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncProgressData &&
          runtimeType == other.runtimeType &&
          totalCount == other.totalCount &&
          dirtyCount == other.dirtyCount &&
          pendingCount == other.pendingCount;

  @override
  int get hashCode => Object.hash(totalCount, dirtyCount, pendingCount);

  @override
  String toString() =>
      'SyncProgressData(clean: $cleanCount, dirty: $dirtyCount, pending: $pendingCount, total: $totalCount, $percentage%)';
}
