import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Identity of this phone and the vehicle it claimed via the backend.
///
/// Device-flow pairing stores [vehicleId] and [accountId] from the backend
/// claim. A record counts as paired when it names a vehicle and
/// [pairedAtUtcMillis] > 0, so a restart does not lose it and existing
/// persisted files remain valid.
///
/// [sharedSecret] is the BLE live-stream key the radio needs to decrypt
/// frames. It is opaque here: the store holds it, never mints it.
class PairingRecord {
  const PairingRecord({
    required this.deviceId,
    required this.deviceName,
    required this.pairedAtUtcMillis,
    this.vehicleId,
    this.accountId,
    this.sharedSecret = '',
  });

  factory PairingRecord.fromMap(Map<String, Object?> map) {
    final deviceId = map['deviceId'] as String?;
    final deviceName = map['deviceName'] as String?;
    final pairedAtUtcMillis = (map['pairedAtUtcMillis'] as num?)?.toInt();
    final vehicleId = map['vehicleId'] as String?;
    final accountId = map['accountId'] as String?;
    final sharedSecret = map['sharedSecret'] as String?;
    if (deviceId == null ||
        deviceId.isEmpty ||
        deviceName == null ||
        deviceName.isEmpty ||
        pairedAtUtcMillis == null ||
        pairedAtUtcMillis < 0) {
      throw const FormatException('Invalid pairing record');
    }
    final hasVehicle = vehicleId != null && vehicleId.isNotEmpty;
    if (pairedAtUtcMillis > 0 && !hasVehicle) {
      throw const FormatException('Invalid pairing record');
    }
    return PairingRecord(
      deviceId: deviceId,
      deviceName: deviceName,
      pairedAtUtcMillis: pairedAtUtcMillis,
      vehicleId: hasVehicle ? vehicleId : null,
      accountId: accountId?.isEmpty == true ? null : accountId,
      sharedSecret: sharedSecret ?? '',
    );
  }

  final String deviceId;
  final String deviceName;
  final int pairedAtUtcMillis;
  final String? vehicleId;
  final String? accountId;
  final String sharedSecret;

  bool get isPaired =>
      vehicleId != null && vehicleId!.isNotEmpty && pairedAtUtcMillis > 0;

  Map<String, Object?> toMap() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'pairedAtUtcMillis': pairedAtUtcMillis,
    if (vehicleId != null) 'vehicleId': vehicleId,
    if (accountId != null) 'accountId': accountId,
    if (sharedSecret.isNotEmpty) 'sharedSecret': sharedSecret,
  };
}

/// Cloud-claim pairing identity. Memory, or a JSON file when [directory] is set.
class PairingStore {
  PairingStore({
    Directory? directory,
    int Function()? nowMillis,
    Random? random,
  }) : _file = directory == null
           ? null
           : File('${directory.path}/pairing.json'),
       _nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final File? _file;
  final int Function() _nowMillis;
  final Random _random;

  PairingRecord? _record;

  PairingRecord? get current => _record;

  bool get isPaired => _record?.isPaired ?? false;

  /// Reads the persisted record. A file that cannot be read or parsed counts
  /// as never paired: a corrupt or legacy record must not block startup, and
  /// the next pairing overwrites the file. Never logs record content.
  Future<void> load() async {
    final file = _file;
    if (file == null || !file.existsSync()) return;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      _record = PairingRecord.fromMap(json);
    } catch (e) {
      // Catch-all on purpose: a failed `as` cast throws TypeError, which is
      // an Error, not an Exception. Only the type is logged, never content.
      debugPrint('Ignoring unreadable pairing record (${e.runtimeType})');
      _record = null;
    }
  }

  /// Stores the vehicle claimed via the backend. This is the device-flow
  /// pairing step. A restart does not lose it.
  ///
  /// [sharedSecret] is the BLE live-stream key when the claim carries one.
  /// Empty until the backend provisions it; the radio stays off without it.
  Future<PairingRecord> completeClaim({
    required String vehicleId,
    required String accountId,
    String? deviceName,
    String? sharedSecret,
  }) async {
    final vId = vehicleId.trim();
    final aId = accountId.trim();
    if (vId.isEmpty) {
      throw ArgumentError('vehicleId cannot be empty');
    }
    if (aId.isEmpty) {
      throw ArgumentError('accountId cannot be empty');
    }
    final existing = _record;
    final secret = (sharedSecret ?? existing?.sharedSecret ?? '').trim();
    final record = PairingRecord(
      deviceId: existing?.deviceId ?? _newDeviceId(),
      deviceName: deviceName ?? existing?.deviceName ?? 'Phone',
      pairedAtUtcMillis: _nowMillis(),
      vehicleId: vId,
      accountId: aId,
      sharedSecret: secret,
    );
    _record = record;
    await _persist();
    return record;
  }

  Future<void> clear() async {
    _record = null;
    final file = _file;
    if (file != null && file.existsSync()) {
      file.deleteSync();
    }
  }

  String _newDeviceId() {
    final stamp = _nowMillis();
    final noise = _random.nextInt(1 << 32).toRadixString(16);
    return 'phone-$stamp-$noise';
  }

  Future<void> _persist() async {
    final file = _file;
    final record = _record;
    if (file == null || record == null) return;
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(record.toMap()));
    tmp.renameSync(file.path);
  }
}
