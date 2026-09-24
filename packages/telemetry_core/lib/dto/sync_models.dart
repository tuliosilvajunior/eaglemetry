part of 'telemetry_dto.dart';

/// Supported synchronization streams between the car and companion devices.
///
/// Problem 2 specifies that summary metadata (trips, charges) syncs first over
/// lightweight channels (BLE), while raw high-frequency telemetry frames sync
/// opportunistically (e.g. over Home Wi-Fi).
enum SyncStreamType {
  sessions,
  telemetryFrames,
  batteryCycles,
  intervals,
  events,

  /// The route of one session as a single row. One directional, like the
  /// measurement streams above, but paged over the moment the row was
  /// written: the car rewrites it while the session runs and once more at
  /// close, and the phone must receive the later version.
  tracks,

  /// Annotation streams, synced both directions. The measurement streams
  /// above stay one directional; these carry places, preferences, session
  /// costs, preference proposals and journeys with last-writer-wins and
  /// tombstones.
  places,
  preferences,
  sessionCosts,
  preferenceProposals,
  journeys,
}

/// Finds a stream type by its wire name. Returns null for an unknown name.
///
/// A peer that names a stream this build does not know is not an error to
/// guess at: the cursor or the acknowledgement is refused instead.
SyncStreamType? _parseStreamType(String? name) {
  if (name == null) return null;
  for (final type in SyncStreamType.values) {
    if (type.name == name) return type;
  }
  return null;
}

/// Thrown when a remote [HlcTimestamp] is too far ahead of the local physical
/// clock to merge.
///
/// This is an expected condition of a peer with a wrong clock, not a defect in
/// this code, so it does not use [StateError]. The caller decides whether to
/// drop the message, warn the user, or refuse the peer.
@immutable
class HlcDriftException implements Exception {
  const HlcDriftException({
    required this.remoteMillis,
    required this.localMillis,
    required this.maxDriftMillis,
  });

  /// Physical component of the remote timestamp, in UTC milliseconds.
  final int remoteMillis;

  /// Local physical clock at the moment of the merge, in UTC milliseconds.
  final int localMillis;

  /// The bound that was exceeded, in milliseconds.
  final int maxDriftMillis;

  /// How far past the bound the remote clock is, in milliseconds.
  int get excessMillis => remoteMillis - localMillis - maxDriftMillis;

  @override
  String toString() =>
      'HlcDriftException(remote: $remoteMillis, local: $localMillis, '
      'maxDrift: $maxDriftMillis, excess: $excessMillis)';
}

/// A Hybrid Logical Clock (HLC) timestamp.
///
/// Combines a wall-clock timestamp with a monotonic logical counter and a
/// device identity. Provides causal ordering across multiple devices (car head
/// unit, phones) whose physical clocks may not be synchronized.
@immutable
class HlcTimestamp implements Comparable<HlcTimestamp> {
  const HlcTimestamp({
    required this.millis,
    required this.counter,
    required this.deviceId,
  });

  /// Maximum permitted physical wall-clock drift in milliseconds (30 minutes).
  ///
  /// Refuses a remote timestamp so far ahead that adopting it would move the
  /// local clock permanently forward. The bound is wide on purpose: this app
  /// uses an HLC because the head unit's clock and the phone's clock are not
  /// guaranteed to agree, so a bound of a minute or two would refuse an
  /// ordinary car and stop the sync altogether. It only has to be tight enough
  /// to catch a clock that is wrong by a scale no vehicle explains.
  ///
  /// The guard is one-sided. A remote clock that runs behind is harmless: the
  /// merge keeps the higher value, and nothing moves forward.
  static const int maxDriftMillis = 30 * 60 * 1000;

  factory HlcTimestamp.now({
    required String deviceId,
    int? wallMillis,
    int counter = 0,
  }) {
    if (deviceId.isEmpty) {
      throw ArgumentError('deviceId cannot be empty');
    }
    return HlcTimestamp(
      millis: wallMillis ?? DateTime.now().millisecondsSinceEpoch,
      counter: counter,
      deviceId: deviceId,
    );
  }

  /// Parses a map. Returns null if required keys are missing, corrupt, or invalid.
  static HlcTimestamp? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final millis = (map['millis'] as num?)?.toInt();
    final counter = (map['counter'] as num?)?.toInt();
    final deviceId = map['deviceId'] as String?;

    if (millis == null ||
        counter == null ||
        deviceId == null ||
        deviceId.isEmpty) {
      return null;
    }
    if (millis < 0 || counter < 0) {
      return null;
    }

    return HlcTimestamp(millis: millis, counter: counter, deviceId: deviceId);
  }

  /// Logical wall-clock component in UTC milliseconds since Unix epoch.
  final int millis;

  /// Monotonic counter incremented on ties or sub-millisecond events.
  final int counter;

  /// Unique identifier of the device generating this timestamp.
  final String deviceId;

  Map<String, Object?> toMap() => {
    'millis': millis,
    'counter': counter,
    'deviceId': deviceId,
  };

  /// Advances this clock for a local event or message generation.
  HlcTimestamp send({int? physicalWallMillis}) {
    final now = physicalWallMillis ?? DateTime.now().millisecondsSinceEpoch;
    final highestMillis = math.max(now, millis);
    final nextCounter = (highestMillis == millis) ? counter + 1 : 0;

    return HlcTimestamp(
      millis: highestMillis,
      counter: nextCounter,
      deviceId: deviceId,
    );
  }

  /// Advances this clock upon receiving a timestamp from a remote peer.
  ///
  /// Throws [HlcDriftException] when the remote physical component is more than
  /// [maxDriftMillis] past the local physical time.
  HlcTimestamp receive({
    required HlcTimestamp remote,
    int? physicalWallMillis,
  }) {
    final now = physicalWallMillis ?? DateTime.now().millisecondsSinceEpoch;
    if (remote.millis - now > maxDriftMillis) {
      throw HlcDriftException(
        remoteMillis: remote.millis,
        localMillis: now,
        maxDriftMillis: maxDriftMillis,
      );
    }

    final highestMillis = math.max(now, math.max(millis, remote.millis));

    int nextCounter;
    if (highestMillis == millis && highestMillis == remote.millis) {
      nextCounter = math.max(counter, remote.counter) + 1;
    } else if (highestMillis == millis) {
      nextCounter = counter + 1;
    } else if (highestMillis == remote.millis) {
      nextCounter = remote.counter + 1;
    } else {
      nextCounter = 0;
    }

    return HlcTimestamp(
      millis: highestMillis,
      counter: nextCounter,
      deviceId: deviceId,
    );
  }

  @override
  int compareTo(HlcTimestamp other) {
    if (millis != other.millis) {
      return millis.compareTo(other.millis);
    }
    if (counter != other.counter) {
      return counter.compareTo(other.counter);
    }
    return deviceId.compareTo(other.deviceId);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HlcTimestamp &&
          runtimeType == other.runtimeType &&
          millis == other.millis &&
          counter == other.counter &&
          deviceId == other.deviceId;

  @override
  int get hashCode => Object.hash(millis, counter, deviceId);

  @override
  String toString() => 'HlcTimestamp($millis:$counter@$deviceId)';
}

/// A tombstone representing the deletion of a user-editable entity or session.
///
/// Ensures deletions propagate cleanly between disconnected devices without
/// resuscitating deleted records during subsequent idempotent merges.
@immutable
class SyncTombstone {
  const SyncTombstone({
    required this.entityId,
    required this.entityType,
    required this.deletedAt,
  });

  /// Parses a tombstone from a map. Returns null if data is corrupt or missing.
  static SyncTombstone? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final entityId = map['entityId'] as String?;
    final entityType = map['entityType'] as String?;
    final deletedAt = HlcTimestamp.fromMap(
      map['deletedAt'] as Map<String, Object?>?,
    );

    if (entityId == null ||
        entityId.isEmpty ||
        entityType == null ||
        entityType.isEmpty ||
        deletedAt == null) {
      return null;
    }

    return SyncTombstone(
      entityId: entityId,
      entityType: entityType,
      deletedAt: deletedAt,
    );
  }

  final String entityId;
  final String entityType;
  final HlcTimestamp deletedAt;

  Map<String, Object?> toMap() => {
    'entityId': entityId,
    'entityType': entityType,
    'deletedAt': deletedAt.toMap(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncTombstone &&
          runtimeType == other.runtimeType &&
          entityId == other.entityId &&
          entityType == other.entityType &&
          deletedAt == other.deletedAt;

  @override
  int get hashCode => Object.hash(entityId, entityType, deletedAt);

  @override
  String toString() =>
      'SyncTombstone(entityId: $entityId, entityType: $entityType, deletedAt: $deletedAt)';
}

/// A synchronization cursor tracking progress per companion device and entity stream.
///
/// [lastConfirmedRecordId] and [lastConfirmedHlc] are one fact in two fields:
/// which record the stream reached, and the causal time it was confirmed. They
/// are both null before anything is confirmed and both set afterwards. A cursor
/// that names a record without a causal time cannot be ordered against another
/// device's cursor, so [fromMap] refuses that pair rather than keeping half of
/// it.
///
/// [updatedAtUtcMillis] records when the car wrote this cursor row.
@immutable
class SyncCursor {
  const SyncCursor({
    required this.deviceId,
    required this.streamType,
    required this.lastConfirmedRecordId,
    required this.lastConfirmedHlc,
    required this.updatedAtUtcMillis,
  });

  /// Parses a cursor from a map. Returns null if data is invalid or corrupt.
  static SyncCursor? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final deviceId = map['deviceId'] as String?;
    final streamType = _parseStreamType(map['streamType'] as String?);
    final lastConfirmedRecordId = map['lastConfirmedRecordId'] as String?;
    final lastConfirmedHlc = HlcTimestamp.fromMap(
      map['lastConfirmedHlc'] as Map<String, Object?>?,
    );
    final updatedAtUtcMillis = (map['updatedAtUtcMillis'] as num?)?.toInt();

    if (deviceId == null ||
        deviceId.isEmpty ||
        streamType == null ||
        updatedAtUtcMillis == null ||
        updatedAtUtcMillis <= 0) {
      return null;
    }
    if ((lastConfirmedRecordId == null) != (lastConfirmedHlc == null)) {
      return null;
    }
    if (lastConfirmedRecordId != null && lastConfirmedRecordId.isEmpty) {
      return null;
    }

    return SyncCursor(
      deviceId: deviceId,
      streamType: streamType,
      lastConfirmedRecordId: lastConfirmedRecordId,
      lastConfirmedHlc: lastConfirmedHlc,
      updatedAtUtcMillis: updatedAtUtcMillis,
    );
  }

  /// Unique identifier of the companion device or car.
  final String deviceId;

  /// Specific entity stream being synchronized (e.g. tripSessions, telemetryFrames).
  final SyncStreamType streamType;

  /// ID of the last confirmed record, in the identity of its own stream.
  ///
  /// It is a session UUID for [SyncStreamType.tripSessions],
  /// [SyncStreamType.chargeSessions] and [SyncStreamType.telemetryFrames],
  /// whose unit of transfer is a whole session. It is the cycle ordinal for
  /// [SyncStreamType.batteryCycles], which the car addresses by ordinal and not
  /// by session. Null when nothing is confirmed yet.
  final String? lastConfirmedRecordId;

  /// Causal HLC timestamp of the last confirmed record. Null with
  /// [lastConfirmedRecordId] and never on its own.
  final HlcTimestamp? lastConfirmedHlc;

  /// The car's wall clock when it wrote this row.
  ///
  /// Not an HLC. The car has no causal clock of its own, and a triple whose
  /// counter never leaves zero would call two writes in the same millisecond
  /// equal — the case the counter exists for. The causal ordering of the
  /// stream lives in [lastConfirmedHlc], which the phone stamps.
  final int updatedAtUtcMillis;

  Map<String, Object?> toMap() => {
    'deviceId': deviceId,
    'streamType': streamType.name,
    'lastConfirmedRecordId': lastConfirmedRecordId,
    'lastConfirmedHlc': lastConfirmedHlc?.toMap(),
    'updatedAtUtcMillis': updatedAtUtcMillis,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncCursor &&
          runtimeType == other.runtimeType &&
          deviceId == other.deviceId &&
          streamType == other.streamType &&
          lastConfirmedRecordId == other.lastConfirmedRecordId &&
          lastConfirmedHlc == other.lastConfirmedHlc &&
          updatedAtUtcMillis == other.updatedAtUtcMillis;

  @override
  int get hashCode => Object.hash(
    deviceId,
    streamType,
    lastConfirmedRecordId,
    lastConfirmedHlc,
    updatedAtUtcMillis,
  );

  @override
  String toString() =>
      'SyncCursor(deviceId: $deviceId, stream: ${streamType.name}, lastRecord: $lastConfirmedRecordId, lastHlc: $lastConfirmedHlc, updated: $updatedAtUtcMillis)';
}

/// A synchronization acknowledgement sent by a receiver once a session or batch
/// has been written completely and verified locally.
@immutable
class SyncAck {
  const SyncAck({
    required this.deviceId,
    required this.streamType,
    required this.recordId,
    required this.syncedAtHlc,
    required this.success,
    this.error,
  });

  /// Parses an ack from a map. Returns null if data is corrupt.
  static SyncAck? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final deviceId = map['deviceId'] as String?;
    final streamType = _parseStreamType(map['streamType'] as String?);
    final recordId = map['recordId'] as String?;
    final syncedAtHlc = HlcTimestamp.fromMap(
      map['syncedAtHlc'] as Map<String, Object?>?,
    );
    final success = map['success'] as bool?;
    final error = map['error'] as String?;

    if (deviceId == null ||
        deviceId.isEmpty ||
        streamType == null ||
        recordId == null ||
        recordId.isEmpty ||
        syncedAtHlc == null ||
        success == null) {
      return null;
    }

    return SyncAck(
      deviceId: deviceId,
      streamType: streamType,
      recordId: recordId,
      syncedAtHlc: syncedAtHlc,
      success: success,
      error: error,
    );
  }

  /// Receiver device that generated this acknowledgement.
  final String deviceId;

  /// The synchronized stream type.
  final SyncStreamType streamType;

  /// ID of the acknowledged record, in the identity of its own stream. It is
  /// read on the same terms as [SyncCursor.lastConfirmedRecordId].
  final String recordId;

  /// Causal HLC timestamp created by the receiver upon confirmation.
  final HlcTimestamp syncedAtHlc;

  /// Whether the session was completely received and written locally.
  final bool success;

  /// Error message when [success] is false.
  final String? error;

  Map<String, Object?> toMap() => {
    'deviceId': deviceId,
    'streamType': streamType.name,
    'recordId': recordId,
    'syncedAtHlc': syncedAtHlc.toMap(),
    'success': success,
    if (error != null) 'error': error,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncAck &&
          runtimeType == other.runtimeType &&
          deviceId == other.deviceId &&
          streamType == other.streamType &&
          recordId == other.recordId &&
          syncedAtHlc == other.syncedAtHlc &&
          success == other.success &&
          error == other.error;

  @override
  int get hashCode =>
      Object.hash(deviceId, streamType, recordId, syncedAtHlc, success, error);

  @override
  String toString() =>
      'SyncAck(deviceId: $deviceId, stream: ${streamType.name}, record: $recordId, success: $success, hlc: $syncedAtHlc)';
}

/// A paged batch of telemetry data returned by `/sync/pull`.
@immutable
/// What one stream holds on the car, against what this phone confirmed.
class SyncStreamCount {
  const SyncStreamCount({required this.total, required this.remaining});

  static SyncStreamCount? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final total = (map['total'] as num?)?.toInt();
    final remaining = (map['remaining'] as num?)?.toInt();
    if (total == null || remaining == null) return null;
    if (total < 0 || remaining < 0) return null;
    return SyncStreamCount(total: total, remaining: remaining);
  }

  /// Every record the car would send on this stream, from the top.
  final int total;

  /// The ones still to come after this device's cursor. Counted per device,
  /// so two phones paired to the same car get different answers.
  final int remaining;

  /// What this phone already holds of the stream.
  int get held => total - remaining;
}

/// The standing state, answered without pulling anything.
///
/// `telemetryFrames` is absent by design. A session holds thousands of frames,
/// so a frame count says nothing a reader can use, and the useful unit —
/// sessions still to fetch — is what the phone already knows from its own
/// archive.
class SyncInventory {
  const SyncInventory({
    required this.generatedAtUtcMillis,
    required this.streams,
  });

  static SyncInventory? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final generatedAtUtcMillis = (map['generatedAtUtcMillis'] as num?)?.toInt();
    final rawStreams = map['streams'];
    if (generatedAtUtcMillis == null ||
        generatedAtUtcMillis <= 0 ||
        rawStreams is! Map) {
      return null;
    }
    final streams = <SyncStreamType, SyncStreamCount>{};
    for (final entry in rawStreams.entries) {
      final stream = SyncStreamType.values
          .where((value) => value.name == entry.key)
          .firstOrNull;
      final raw = entry.value;
      if (stream == null || raw is! Map) continue;
      final count = SyncStreamCount.fromMap(raw.cast<String, Object?>());
      if (count != null) streams[stream] = count;
    }
    return SyncInventory(
      generatedAtUtcMillis: generatedAtUtcMillis,
      streams: Map.unmodifiable(streams),
    );
  }

  final int generatedAtUtcMillis;
  final Map<SyncStreamType, SyncStreamCount> streams;
}

class SyncBatch {
  const SyncBatch({
    required this.protocolVersion,
    required this.streamType,
    required this.items,
    required this.nextCursor,
    required this.hasMore,
    required this.generatedAtUtcMillis,
    this.remaining,
  });

  /// Current wire protocol version supported by this client.
  static const int currentProtocolVersion = 2;

  /// Parses a batch from a map. Returns null if data is corrupt or unsupported.
  static SyncBatch? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final protocolVersion = (map['protocolVersion'] as num?)?.toInt();
    final streamType = _parseStreamType(map['streamType'] as String?);
    final rawItems = map['items'] as List<Object?>?;
    final nextCursor = map['nextCursor'] as String?;
    final hasMore = map['hasMore'] as bool?;
    final generatedAtUtcMillis = (map['generatedAtUtcMillis'] as num?)?.toInt();

    if (protocolVersion == null ||
        protocolVersion != currentProtocolVersion ||
        streamType == null ||
        rawItems == null ||
        hasMore == null ||
        generatedAtUtcMillis == null ||
        generatedAtUtcMillis <= 0) {
      return null;
    }

    final items = <Map<String, Object?>>[];
    for (final item in rawItems) {
      if (item is Map) {
        items.add(item.cast<String, Object?>());
      } else {
        return null;
      }
    }

    return SyncBatch(
      protocolVersion: protocolVersion,
      streamType: streamType,
      items: List.unmodifiable(items),
      nextCursor: nextCursor,
      hasMore: hasMore,
      generatedAtUtcMillis: generatedAtUtcMillis,
      remaining: (map['remaining'] as num?)?.toInt(),
    );
  }

  /// Wire protocol version of the envelope.
  final int protocolVersion;

  /// The synchronized stream type.
  final SyncStreamType streamType;

  /// Serialized records for this batch.
  final List<Map<String, Object?>> items;

  /// The cursor of the last record in this batch to resume subsequent requests.
  final String? nextCursor;

  /// True if more records are available in this stream after this batch.
  final bool hasMore;

  /// Timestamp on the car's wall clock when this batch was packaged.
  final int generatedAtUtcMillis;

  /// How many records the stream still holds after this batch, or null when
  /// the car did not say.
  ///
  /// The car counts it with the same condition it pages over, inside the
  /// request the phone already made, so it costs no round trip and is
  /// recounted on every page. It answers "how much is left", which a total
  /// read once at the start of a run stops answering the moment the car
  /// closes a session.
  ///
  /// Null is a real state, not a zero: a car built before 2026-08-18 does not
  /// send the field, and `protocolVersion` did not move so that the two builds
  /// still meet. A reader shows a plain counter then, never a bar at 100 %.
  final int? remaining;

  Map<String, Object?> toMap() => {
    'protocolVersion': protocolVersion,
    'streamType': streamType.name,
    'items': items,
    'nextCursor': nextCursor,
    'hasMore': hasMore,
    'generatedAtUtcMillis': generatedAtUtcMillis,
    'remaining': remaining,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncBatch &&
          runtimeType == other.runtimeType &&
          protocolVersion == other.protocolVersion &&
          streamType == other.streamType &&
          nextCursor == other.nextCursor &&
          hasMore == other.hasMore &&
          generatedAtUtcMillis == other.generatedAtUtcMillis &&
          remaining == other.remaining &&
          _listEquals(items, other.items);

  @override
  int get hashCode => Object.hash(
    protocolVersion,
    streamType,
    nextCursor,
    hasMore,
    generatedAtUtcMillis,
    remaining,
    Object.hashAll(
      items.map(
        (m) =>
            Object.hashAll(m.entries.map((e) => Object.hash(e.key, e.value))),
      ),
    ),
  );

  @override
  String toString() =>
      'SyncBatch(v$protocolVersion, stream: ${streamType.name}, count: ${items.length}, hasMore: $hasMore, nextCursor: $nextCursor)';

  static bool _listEquals(
    List<Map<String, Object?>> a,
    List<Map<String, Object?>> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final mapA = a[i];
      final mapB = b[i];
      if (mapA.length != mapB.length) return false;
      for (final key in mapA.keys) {
        if (mapA[key] != mapB[key]) return false;
      }
    }
    return true;
  }
}

/// A paired companion device authorized to synchronize telemetry.
@immutable
class CompanionDevice {
  const CompanionDevice({
    required this.deviceId,
    required this.deviceName,
    required this.pairedAtUtcMillis,
    this.isBleStreamActive = false,
  });

  static CompanionDevice? fromMap(Map<String, Object?>? map) {
    if (map == null) return null;
    final deviceId = map['deviceId'] as String?;
    final deviceName = map['deviceName'] as String?;
    final pairedAtUtcMillis = (map['pairedAtUtcMillis'] as num?)?.toInt();
    final isBleStreamActive = map['isBleStreamActive'] as bool? ?? false;

    if (deviceId == null ||
        deviceId.isEmpty ||
        deviceName == null ||
        deviceName.isEmpty ||
        pairedAtUtcMillis == null ||
        pairedAtUtcMillis <= 0) {
      return null;
    }

    return CompanionDevice(
      deviceId: deviceId,
      deviceName: deviceName,
      pairedAtUtcMillis: pairedAtUtcMillis,
      isBleStreamActive: isBleStreamActive,
    );
  }

  final String deviceId;
  final String deviceName;
  final int pairedAtUtcMillis;

  /// Whether the car is pushing the BLE live stream to a connected phone.
  ///
  /// The stream is one-way, so the car cannot tell which paired phone is on
  /// the other end. This is a service-level fact and reads the same on every
  /// paired device.
  final bool isBleStreamActive;

  Map<String, Object?> toMap() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
    'pairedAtUtcMillis': pairedAtUtcMillis,
    'isBleStreamActive': isBleStreamActive,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompanionDevice &&
          runtimeType == other.runtimeType &&
          deviceId == other.deviceId &&
          deviceName == other.deviceName &&
          pairedAtUtcMillis == other.pairedAtUtcMillis &&
          isBleStreamActive == other.isBleStreamActive;

  @override
  int get hashCode =>
      Object.hash(deviceId, deviceName, pairedAtUtcMillis, isBleStreamActive);

  @override
  String toString() =>
      'CompanionDevice(deviceId: $deviceId, deviceName: $deviceName, pairedAt: $pairedAtUtcMillis, isBleStreamActive: $isBleStreamActive)';
}

/// What one manual cloud upload pass did.
///
/// The car reports this after the pass finishes, so the screen states what
/// moved instead of guessing. `cloudReady` false means this build has cloud
/// sync off: the button must say so plainly rather than pretend to sync.
/// `paired` false means the car is not paired yet (or its pairing was
/// revoked): the car attempted nothing, so the screen must not call it a
/// failure.
@immutable
class CloudSyncResult {
  const CloudSyncResult({
    required this.cloudReady,
    required this.movedRows,
    required this.failed,
    this.paired = true,
  });

  /// The car answered nothing usable. The screen states the failure, never a
  /// guess about what moved.
  static const CloudSyncResult unknown = CloudSyncResult(
    cloudReady: true,
    movedRows: 0,
    failed: true,
  );

  static CloudSyncResult fromMap(Map<String, Object?>? map) {
    if (map == null) return unknown;
    final moved = (map['movedRows'] as num?)?.toInt() ?? 0;
    return CloudSyncResult(
      cloudReady: map['cloudReady'] as bool? ?? true,
      paired: map['paired'] as bool? ?? true,
      movedRows: moved < 0 ? 0 : moved,
      failed: map['failed'] as bool? ?? false,
    );
  }

  /// Whether this build can reach the cloud at all.
  final bool cloudReady;

  /// Whether the car is paired, so an upload can run at all.
  final bool paired;

  /// Telemetry plus annotation rows the pass moved.
  final int movedRows;

  /// Whether the pass ended in failure.
  final bool failed;

  Map<String, Object?> toMap() => {
    'cloudReady': cloudReady,
    'paired': paired,
    'movedRows': movedRows,
    'failed': failed,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CloudSyncResult &&
          runtimeType == other.runtimeType &&
          cloudReady == other.cloudReady &&
          paired == other.paired &&
          movedRows == other.movedRows &&
          failed == other.failed;

  @override
  int get hashCode => Object.hash(cloudReady, paired, movedRows, failed);

  @override
  String toString() =>
      'CloudSyncResult(ready: $cloudReady, paired: $paired, moved: $movedRows, failed: $failed)';
}
