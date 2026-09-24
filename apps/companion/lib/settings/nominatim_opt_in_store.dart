import 'package:flutter/foundation.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../sync/companion_archive.dart';
import '../sync/nominatim_gateway.dart';

/// Companion-only opt-in for Nominatim AutoName.
///
/// Stored as synced preference `places.nominatimOptIn` (device scope, default
/// false) via the annotation channel. The gateway itself is gated by the
/// boolean passed to [NominatimGateway.reverse]; this store is the Settings
/// toggle's persistence and observation layer.
class NominatimOptInStore extends ChangeNotifier {
  NominatimOptInStore(this.archive);

  final CompanionArchive? archive;

  bool _enabled = false;

  bool get enabled => _enabled;

  /// Loads the stored value. Missing row means off (default).
  Future<void> load() async {
    final db = archive?.database;
    if (db == null) return;
    try {
      final rows = await db.allPreferences();
      for (final row in rows) {
        if (row['deletedAtUtcMillis'] != null) continue;
        if (row['key'] != NominatimGateway.preferenceKey) continue;
        // Accept any scope for resilience; writer uses device scope.
        final raw = row['value'] as String?;
        if (raw == null) continue;
        final value = raw.toLowerCase() == 'true';
        if (value != _enabled) {
          _enabled = value;
          notifyListeners();
        }
        return;
      }
      // No row — default false, but notify if we were true.
      if (_enabled) {
        _enabled = false;
        notifyListeners();
      }
    } catch (_) {
      // Keep default.
    }
  }

  /// Persists [value] via the annotation channel.
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();

    final store = archive;
    if (store == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final row = <String, Object?>{
      'scope': NominatimGateway.preferenceScope,
      'key': NominatimGateway.preferenceKey,
      'value': value.toString(),
      'updatedAtUtcMillis': now,
      'origin': kAnnotationOriginPhone,
      'deletedAtUtcMillis': null,
    };
    await store.upsertPreference(row);
    await store.database.enqueueAnnotationPush(
      SyncStreamType.preferences.name,
      row,
    );
  }

  /// Reads fresh value without mutating local cache.
  Future<bool> readFresh() async {
    final db = archive?.database;
    if (db == null) return _enabled;
    final rows = await db.allPreferences();
    for (final row in rows) {
      if (row['deletedAtUtcMillis'] != null) continue;
      if (row['key'] != NominatimGateway.preferenceKey) continue;
      final raw = row['value'] as String?;
      if (raw == null) continue;
      return raw.toLowerCase() == 'true';
    }
    return false;
  }
}
