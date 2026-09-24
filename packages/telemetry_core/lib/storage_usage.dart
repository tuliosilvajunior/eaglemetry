/// How much disk the app's history occupies.
///
/// The number is the logical size of the database (used pages) plus the
/// WAL/SHM sidecars where they exist, obtained without scanning any table.
/// It is read from `PRAGMA page_count`, `freelist_count` and `page_size` —
/// O(1) header reads — plus `File.length` for the sidecars. No query ever
/// reads or counts rows to produce this value.
///
/// With `auto_vacuum = FULL` (the setting on all four car snapshots) the
/// file truncates on every commit, so `page_count * page_size` and
/// `File.length` are the same after a wipe (e.g. 15_102 pages / 47 MB
/// before a DELETE, 618 pages / 2.5 MB after). The pragma form is kept
/// because it makes the intent explicit and it works the same with or
/// without truncation.
class StorageUsage {
  const StorageUsage({
    required this.bytes,
    required this.databaseBytes,
    required this.walBytes,
    required this.shmBytes,
  });

  /// The total bytes the app's stored history occupies on disk.
  ///
  /// This is what Settings shows: one line, one number.
  final int bytes;

  /// The logical size of the main database file (used pages * page size).
  ///
  /// With `auto_vacuum = FULL` this equals the file length. Without it the
  /// file would keep free pages and `File.length` would stay large after a
  /// wipe, while this stays small.
  final int databaseBytes;

  /// The WAL file, zero when absent (file length).
  final int walBytes;

  /// The SHM file, zero when absent (file length).
  final int shmBytes;

  /// Whether the size is known. A total failure returns `bytes = -1` and this
  /// is `false`, so the UI can show `--` instead of `0 B`.
  bool get available => bytes >= 0;

  factory StorageUsage.fromMap(Map<String, Object?> map) {
    int asInt(Object? value) => (value as num?)?.toInt() ?? 0;
    final db = asInt(map['databaseBytes'] ?? map['database_bytes']);
    final wal = asInt(map['walBytes'] ?? map['wal_bytes']);
    final shm = asInt(map['shmBytes'] ?? map['shm_bytes']);
    final total = map['bytes'] ?? map['totalBytes'];
    final bytes = total != null ? asInt(total) : (db + wal + shm);
    return StorageUsage(
      bytes: bytes,
      databaseBytes: db,
      walBytes: wal,
      shmBytes: shm,
    );
  }

  Map<String, Object?> toMap() => {
    'bytes': bytes,
    'databaseBytes': databaseBytes,
    'walBytes': walBytes,
    'shmBytes': shmBytes,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StorageUsage &&
          other.bytes == bytes &&
          other.databaseBytes == databaseBytes &&
          other.walBytes == walBytes &&
          other.shmBytes == shmBytes;

  @override
  int get hashCode => Object.hash(bytes, databaseBytes, walBytes, shmBytes);

  @override
  String toString() => 'StorageUsage(bytes: $bytes)';
}

/// Formats [bytes] for a Settings line.
///
/// Keeps one decimal for MB, no decimal for KB, and shows B below 1 KB.
/// Pure and test-covered: the UI calls this, not ad-hoc division in a widget.
///
/// The decimal separator follows [locale]: `pt`, `ru` and `es` use `,`,
/// others use `.`. A negative value means the size is unknown and returns
/// `--`, so a total failure does not claim `0 B`.
String formatStorageBytes(int bytes, {String locale = 'en'}) {
  if (bytes < 0) return '--';
  String sep(String s) {
    final dec =
        locale.toLowerCase().startsWith('pt') ||
            locale.toLowerCase().startsWith('ru') ||
            locale.toLowerCase().startsWith('es')
        ? ','
        : '.';
    return dec == '.' ? s : s.replaceAll('.', ',');
  }

  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final kb = bytes / 1024;
    return '${sep(kb.toStringAsFixed(kb >= 10 ? 0 : 1))} KB';
  }
  final mb = bytes / (1024 * 1024);
  if (mb < 1024) {
    return '${sep(mb.toStringAsFixed(mb >= 10 ? 1 : 2))} MB';
  }
  final gb = mb / 1024;
  return '${sep(gb.toStringAsFixed(gb >= 10 ? 1 : 2))} GB';
}
