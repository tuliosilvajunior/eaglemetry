import 'cloud_uploader.dart';

/// A car link found in the cloud for the signed-in account.
///
/// The vehicle id names the car; the account id stamps the restored record.
typedef RestoredPairing = ({String vehicleId, String accountId});

/// Finds this account's car in the cloud, so a fresh install skips pairing.
///
/// Reads through [sink], never past it, so tests fake the two tables. Picks
/// the most recently linked car: the active `vehicle_ownership.created_at`
/// for this account when present, else `vehicle.created_at` for cars linked
/// before ownership rows existed.
///
/// Skips a car whose ownership rows for this account are all revoked: the
/// link was cut and must not come back. A car moved to another account is
/// already unreadable here, so nothing can bring it back.
///
/// Answers null when there is nothing to restore or the lookup fails. The
/// caller keeps today's behavior then (show pairing) and a later start
/// retries.
Future<RestoredPairing?> restoreOwnedVehicle({
  required CloudSink sink,
  required String accountId,
}) async {
  final List<Map<String, Object?>> vehicles;
  final List<Map<String, Object?>> ownerships;
  try {
    vehicles = await sink.fetch('vehicle');
    ownerships = await sink.fetch('vehicle_ownership');
  } catch (_) {
    return null;
  }

  String? bestVehicle;
  var bestLinkedMillis = 0;
  var bestVehicleMillis = 0;
  var found = false;

  for (final vehicle in vehicles) {
    final vehicleId = _text(vehicle['vehicle_id']);
    if (vehicleId == null) continue;

    final allLinks = [
      for (final row in ownerships)
        if (_text(row['vehicle_id']) == vehicleId) row,
    ];

    int? linkedMillis;
    final vehicleMillis = _millis(vehicle['created_at']) ?? 0;

    if (allLinks.isNotEmpty) {
      final otherActive = allLinks.any(
        (row) =>
            row['revoked_at'] == null && _text(row['account_id']) != accountId,
      );
      if (otherActive) continue;

      final myActive = [
        for (final row in allLinks)
          if (_text(row['account_id']) == accountId &&
              row['revoked_at'] == null)
            row,
      ];
      if (myActive.isEmpty) continue;

      final ownedMillis = _millis(myActive.first['created_at']);
      linkedMillis = ownedMillis ?? vehicleMillis;
    } else {
      if (_text(vehicle['account_id']) != accountId) continue;
      linkedMillis = vehicleMillis;
    }

    final isBetter =
        !found ||
        linkedMillis > bestLinkedMillis ||
        (linkedMillis == bestLinkedMillis &&
            vehicleMillis > bestVehicleMillis) ||
        (linkedMillis == bestLinkedMillis &&
            vehicleMillis == bestVehicleMillis &&
            vehicleId.compareTo(bestVehicle!) > 0);

    if (isBetter) {
      found = true;
      bestLinkedMillis = linkedMillis;
      bestVehicleMillis = vehicleMillis;
      bestVehicle = vehicleId;
    }
  }

  final id = bestVehicle;
  if (!found || id == null) return null;
  return (vehicleId: id, accountId: accountId);
}

String? _text(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

int? _millis(Object? value) {
  if (value is int) return value;
  if (value is! String) return null;
  return DateTime.tryParse(value)?.millisecondsSinceEpoch;
}
