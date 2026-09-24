import 'package:telemetry_core/telemetry_core.dart';

/// Why a cloud pull stopped.
enum SyncRunStatus { completed, failed }

/// Where a pull is, as one page lands.
///
/// The denominator is not held here. [remaining] is what the last page
/// reported, counted with the same condition the pull pages over. A total
/// counted at the start stops being true the moment the car uploads more,
/// and the phone has no way to tell.
class SyncProgress {
  const SyncProgress({
    required this.stream,
    required this.recordsWritten,
    this.remaining,
    this.sessionIndex,
    this.sessionCount,
  });

  /// The stream this page belonged to.
  final SyncStreamType stream;

  /// Records written in this run, for this stream.
  final int recordsWritten;

  /// What is still to come after the last page, or null when unknown.
  final int? remaining;

  /// Which session a per-session page is on, and how many it found.
  /// Null on every other stream.
  final int? sessionIndex;
  final int? sessionCount;

  /// How far this stream is, from 0 to 1, or null when the denominator
  /// is unknown.
  ///
  /// A reader with null must show a plain counter. A bar drawn from a missing
  /// denominator would sit at 100 % while the transfer is still running.
  double? get fraction {
    final left = remaining;
    if (left == null) return null;
    final total = recordsWritten + left;
    if (total <= 0) return 1;
    return recordsWritten / total;
  }
}

/// Result of one cloud pull.
class SyncRunReport {
  const SyncRunReport({
    required this.status,
    required this.ackedRecords,
    this.error,
  });

  final SyncRunStatus status;
  final int ackedRecords;
  final Object? error;
}
