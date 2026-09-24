import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  group('HlcTimestamp', () {
    test('compares by millis first', () {
      const t1 = HlcTimestamp(millis: 100, counter: 5, deviceId: 'car');
      const t2 = HlcTimestamp(millis: 200, counter: 1, deviceId: 'car');
      expect(t1.compareTo(t2), lessThan(0));
      expect(t2.compareTo(t1), greaterThan(0));
    });

    test('compares by counter on equal millis', () {
      const t1 = HlcTimestamp(millis: 100, counter: 1, deviceId: 'car');
      const t2 = HlcTimestamp(millis: 100, counter: 2, deviceId: 'car');
      expect(t1.compareTo(t2), lessThan(0));
    });

    test('compares by deviceId on equal millis and counter', () {
      const t1 = HlcTimestamp(millis: 100, counter: 1, deviceId: 'car');
      const t2 = HlcTimestamp(millis: 100, counter: 1, deviceId: 'phone');
      expect(t1.compareTo(t2), lessThan(0));
    });

    test('advances correctly on local send ahead of physical clock', () {
      const local = HlcTimestamp(millis: 200, counter: 0, deviceId: 'car');
      final advanced = local.send(
        physicalWallMillis: 150, // Physical clock is behind
      );
      expect(advanced.millis, 200);
      expect(advanced.counter, 1);
      expect(advanced.deviceId, 'car');
    });

    test('resets counter on send when physical clock moves ahead', () {
      const local = HlcTimestamp(millis: 100, counter: 5, deviceId: 'car');
      final advanced = local.send(physicalWallMillis: 150);
      expect(advanced.millis, 150);
      expect(advanced.counter, 0);
      expect(advanced.deviceId, 'car');
    });

    test('advances correctly on receiving newer remote timestamp', () {
      const local = HlcTimestamp(millis: 100, counter: 0, deviceId: 'car');
      const remote = HlcTimestamp(millis: 200, counter: 3, deviceId: 'phone');
      final advanced = local.receive(remote: remote, physicalWallMillis: 150);
      expect(advanced.millis, 200);
      expect(advanced.counter, 4);
      expect(advanced.deviceId, 'car');
    });

    test('handles three-way tie between physical, local and remote clocks', () {
      const local = HlcTimestamp(millis: 200, counter: 2, deviceId: 'car');
      const remote = HlcTimestamp(millis: 200, counter: 5, deviceId: 'phone');
      final advanced = local.receive(remote: remote, physicalWallMillis: 200);
      expect(advanced.millis, 200);
      expect(advanced.counter, 6); // max(2, 5) + 1
      expect(advanced.deviceId, 'car');
    });

    test(
      'resets counter when physical clock is strictly ahead of both local and remote',
      () {
        const local = HlcTimestamp(millis: 100, counter: 10, deviceId: 'car');
        const remote = HlcTimestamp(
          millis: 100,
          counter: 20,
          deviceId: 'phone',
        );
        final advanced = local.receive(remote: remote, physicalWallMillis: 300);
        expect(advanced.millis, 300);
        expect(advanced.counter, 0);
      },
    );

    test('rejects remote timestamp exceeding max clock drift', () {
      const local = HlcTimestamp(millis: 1000, counter: 0, deviceId: 'car');
      const remote = HlcTimestamp(
        millis: 1000 + HlcTimestamp.maxDriftMillis + 1,
        counter: 0,
        deviceId: 'phone',
      );
      expect(
        () => local.receive(remote: remote, physicalWallMillis: 1000),
        throwsA(isA<HlcDriftException>()),
      );
    });

    test('accepts a remote timestamp at the drift bound', () {
      const local = HlcTimestamp(millis: 1000, counter: 0, deviceId: 'car');
      const remote = HlcTimestamp(
        millis: 1000 + HlcTimestamp.maxDriftMillis,
        counter: 0,
        deviceId: 'phone',
      );
      final advanced = local.receive(remote: remote, physicalWallMillis: 1000);
      expect(advanced.millis, remote.millis);
      expect(advanced.counter, 1);
      expect(advanced.deviceId, 'car');
    });

    test(
      'accepts a remote clock that runs behind, and keeps the local time',
      () {
        const local = HlcTimestamp(millis: 5000, counter: 0, deviceId: 'car');
        const remote = HlcTimestamp(millis: 1, counter: 9, deviceId: 'phone');
        final advanced = local.receive(
          remote: remote,
          physicalWallMillis: 4000,
        );
        expect(advanced.millis, 5000);
        expect(advanced.counter, 1);
      },
    );

    test('rejects malformed or empty maps', () {
      expect(HlcTimestamp.fromMap(null), isNull);
      expect(HlcTimestamp.fromMap(const {}), isNull);
      expect(HlcTimestamp.fromMap(const {'millis': 100}), isNull);
      expect(
        HlcTimestamp.fromMap(const {
          'millis': 100,
          'counter': 0,
          'deviceId': '',
        }),
        isNull,
      );
      expect(
        HlcTimestamp.fromMap(const {
          'millis': -1,
          'counter': 0,
          'deviceId': 'car',
        }),
        isNull,
      );
    });

    test('serializes and deserializes valid map', () {
      const original = HlcTimestamp(
        millis: 123456789,
        counter: 42,
        deviceId: 'phone-xyz',
      );
      final map = original.toMap();
      final restored = HlcTimestamp.fromMap(map);
      expect(restored, equals(original));
    });
  });

  group('Sync Models', () {
    test('SyncTombstone serializes, deserializes, and verifies equality', () {
      const tombstone = SyncTombstone(
        entityId: 'session-123',
        entityType: 'charge_session',
        deletedAt: HlcTimestamp(millis: 1000, counter: 0, deviceId: 'phone-1'),
      );
      final map = tombstone.toMap();
      final restored = SyncTombstone.fromMap(map);
      expect(restored, equals(tombstone));

      // Rejects malformed
      expect(SyncTombstone.fromMap(null), isNull);
      expect(SyncTombstone.fromMap(const {}), isNull);
      expect(SyncTombstone.fromMap(const {'entityId': '123'}), isNull);
    });

    test(
      'SyncCursor serializes, deserializes with streamType, and checks equality',
      () {
        const cursor = SyncCursor(
          deviceId: 'phone-1',
          streamType: SyncStreamType.sessions,
          lastConfirmedRecordId: 'session-999',
          lastConfirmedHlc: HlcTimestamp(
            millis: 5000,
            counter: 1,
            deviceId: 'phone-1',
          ),
          updatedAtUtcMillis: 6000,
        );
        final map = cursor.toMap();
        final restored = SyncCursor.fromMap(map);
        expect(restored, equals(cursor));

        // Rejects invalid stream type or missing fields
        expect(SyncCursor.fromMap(null), isNull);
        expect(
          SyncCursor.fromMap(const {'deviceId': 'p1', 'streamType': 'unknown'}),
          isNull,
        );
      },
    );

    test('SyncCursor round-trips a stream that has confirmed nothing', () {
      const cursor = SyncCursor(
        deviceId: 'phone-1',
        streamType: SyncStreamType.telemetryFrames,
        lastConfirmedRecordId: null,
        lastConfirmedHlc: null,
        updatedAtUtcMillis: 6000,
      );
      expect(SyncCursor.fromMap(cursor.toMap()), equals(cursor));
    });

    test('SyncCursor refuses a record id without its causal timestamp', () {
      // A record named, but its causal time missing or corrupt.
      expect(
        SyncCursor.fromMap({
          'deviceId': 'phone-1',
          'streamType': SyncStreamType.sessions.name,
          'lastConfirmedRecordId': 'session-999',
          'lastConfirmedHlc': null,
          'updatedAtUtcMillis': 6000,
        }),
        isNull,
      );
      expect(
        SyncCursor.fromMap({
          'deviceId': 'phone-1',
          'streamType': SyncStreamType.sessions.name,
          'lastConfirmedRecordId': 'session-999',
          'lastConfirmedHlc': const {'millis': 5000},
          'updatedAtUtcMillis': 6000,
        }),
        isNull,
      );

      // A causal time without the record it belongs to.
      expect(
        SyncCursor.fromMap({
          'deviceId': 'phone-1',
          'streamType': SyncStreamType.sessions.name,
          'lastConfirmedRecordId': null,
          'lastConfirmedHlc': const HlcTimestamp(
            millis: 5000,
            counter: 1,
            deviceId: 'phone-1',
          ).toMap(),
          'updatedAtUtcMillis': 6000,
        }),
        isNull,
      );

      // An empty record id names nothing.
      expect(
        SyncCursor.fromMap({
          'deviceId': 'phone-1',
          'streamType': SyncStreamType.sessions.name,
          'lastConfirmedRecordId': '',
          'lastConfirmedHlc': const HlcTimestamp(
            millis: 5000,
            counter: 1,
            deviceId: 'phone-1',
          ).toMap(),
          'updatedAtUtcMillis': 6000,
        }),
        isNull,
      );
    });

    test('SyncCursor carries a cycle ordinal for the batteryCycles stream', () {
      const cursor = SyncCursor(
        deviceId: 'phone-1',
        streamType: SyncStreamType.batteryCycles,
        lastConfirmedRecordId: '42',
        lastConfirmedHlc: HlcTimestamp(
          millis: 5000,
          counter: 0,
          deviceId: 'car',
        ),
        updatedAtUtcMillis: 6000,
      );
      expect(SyncCursor.fromMap(cursor.toMap()), equals(cursor));
    });

    test('SyncAck serializes, deserializes, and checks equality', () {
      const ackSuccess = SyncAck(
        deviceId: 'phone-1',
        streamType: SyncStreamType.intervals,
        recordId: 'session-999:1000',
        syncedAtHlc: HlcTimestamp(
          millis: 7000,
          counter: 0,
          deviceId: 'phone-1',
        ),
        success: true,
      );
      final mapSuccess = ackSuccess.toMap();
      expect(mapSuccess.containsKey('error'), isFalse);
      final restoredSuccess = SyncAck.fromMap(mapSuccess);
      expect(restoredSuccess, equals(ackSuccess));

      const ackError = SyncAck(
        deviceId: 'phone-1',
        streamType: SyncStreamType.intervals,
        recordId: 'session-999:1000',
        syncedAtHlc: HlcTimestamp(
          millis: 7000,
          counter: 1,
          deviceId: 'phone-1',
        ),
        success: false,
        error: 'checksum_mismatch',
      );
      final mapError = ackError.toMap();
      expect(mapError['error'], 'checksum_mismatch');
      final restoredError = SyncAck.fromMap(mapError);
      expect(restoredError, equals(ackError));
      expect(restoredError?.error, 'checksum_mismatch');
    });

    test('SyncAck refuses an unknown stream or a missing record', () {
      final syncedAt = const HlcTimestamp(
        millis: 7000,
        counter: 0,
        deviceId: 'phone-1',
      ).toMap();

      expect(SyncAck.fromMap(null), isNull);
      expect(
        SyncAck.fromMap({
          'deviceId': 'phone-1',
          'streamType': 'unknown',
          'recordId': 'session-999',
          'syncedAtHlc': syncedAt,
          'success': true,
        }),
        isNull,
      );
      expect(
        SyncAck.fromMap({
          'deviceId': 'phone-1',
          'streamType': SyncStreamType.sessions.name,
          'recordId': '',
          'syncedAtHlc': syncedAt,
          'success': true,
        }),
        isNull,
      );
      expect(
        SyncAck.fromMap({
          'deviceId': 'phone-1',
          'streamType': SyncStreamType.sessions.name,
          'recordId': 'session-999',
          'syncedAtHlc': syncedAt,
          'success': null,
        }),
        isNull,
      );
    });

    test('SyncBatch serializes, deserializes, and validates fields', () {
      const batch = SyncBatch(
        protocolVersion: 2,
        streamType: SyncStreamType.sessions,
        items: [
          {'id': 'session-1', 'startedAtUtcMillis': 1000},
          {'id': 'session-2', 'startedAtUtcMillis': 2000},
        ],
        nextCursor: 'session-2',
        hasMore: true,
        generatedAtUtcMillis: 5000,
      );

      final map = batch.toMap();
      expect(map['protocolVersion'], 2);
      expect(map['streamType'], 'sessions');
      expect(map['items'], isA<List>());
      expect(map['nextCursor'], 'session-2');
      expect(map['hasMore'], isTrue);
      expect(map['generatedAtUtcMillis'], 5000);

      final restored = SyncBatch.fromMap(map);
      expect(restored, equals(batch));
      expect(restored.hashCode, equals(batch.hashCode));
      expect(restored.toString(), contains('sessions'));

      // Rejects invalid envelopes
      expect(SyncBatch.fromMap(null), isNull);
      expect(
        SyncBatch.fromMap({
          'protocolVersion': 0, // invalid version
          'streamType': 'sessions',
          'items': [],
          'hasMore': false,
          'generatedAtUtcMillis': 5000,
        }),
        isNull,
      );
      expect(
        SyncBatch.fromMap({
          'protocolVersion': 3, // unsupported future version
          'streamType': 'sessions',
          'items': [],
          'hasMore': false,
          'generatedAtUtcMillis': 5000,
        }),
        isNull,
      );
      expect(
        SyncBatch.fromMap({
          'protocolVersion': 2,
          'streamType': 'unknownStream',
          'items': [],
          'hasMore': false,
          'generatedAtUtcMillis': 5000,
        }),
        isNull,
      );
      expect(
        SyncBatch.fromMap({
          'protocolVersion': 2,
          'streamType': 'sessions',
          'items': ['not a map'],
          'hasMore': false,
          'generatedAtUtcMillis': 5000,
        }),
        isNull,
      );
      expect(
        SyncBatch.fromMap({
          'protocolVersion': 2,
          'streamType': 'sessions',
          'items': [],
          'hasMore': false,
          'generatedAtUtcMillis': 0,
        }),
        isNull,
      );
    });
  });

  group('CompanionDevice & CloudSyncResult', () {
    test('CompanionDevice serializes and parses properly', () {
      const device = CompanionDevice(
        deviceId: 'phone-xyz',
        deviceName: 'Pixel 8',
        pairedAtUtcMillis: 1700000000000,
        isBleStreamActive: true,
      );

      final map = device.toMap();
      expect(map['deviceId'], 'phone-xyz');
      expect(map['deviceName'], 'Pixel 8');
      expect(map['pairedAtUtcMillis'], 1700000000000);
      expect(map['isBleStreamActive'], true);

      final restored = CompanionDevice.fromMap(map);
      expect(restored, equals(device));
      expect(restored?.isBleStreamActive, isTrue);
      expect(restored.hashCode, equals(device.hashCode));
      expect(CompanionDevice.fromMap(null), isNull);
      expect(CompanionDevice.fromMap({'deviceId': ''}), isNull);
    });

    test('CloudSyncResult parses the car report', () {
      const report = CloudSyncResult(
        cloudReady: true,
        movedRows: 12,
        failed: false,
      );
      final restored = CloudSyncResult.fromMap(report.toMap());
      expect(restored, equals(report));
      expect(restored.hashCode, equals(report.hashCode));
    });

    test('CloudSyncResult answers failure on a null map, never a guess', () {
      // Null means the car answered nothing usable. The screen states the
      // failure; it must not read it as "nothing moved".
      expect(CloudSyncResult.fromMap(null), equals(CloudSyncResult.unknown));
      expect(CloudSyncResult.fromMap(null).failed, isTrue);
    });

    test('CloudSyncResult keeps the unpaired state apart from failure', () {
      const report = CloudSyncResult(
        cloudReady: true,
        paired: false,
        movedRows: 0,
        failed: false,
      );
      final restored = CloudSyncResult.fromMap(report.toMap());
      expect(restored, equals(report));
      expect(restored.paired, isFalse);
      expect(restored.failed, isFalse);
      expect(
        restored,
        isNot(
          equals(
            const CloudSyncResult(
              cloudReady: true,
              movedRows: 0,
              failed: false,
            ),
          ),
        ),
      );
      // An older car build sends no `paired` key: read it as paired.
      expect(
        CloudSyncResult.fromMap(const {
          'cloudReady': true,
          'movedRows': 0,
          'failed': false,
        }).paired,
        isTrue,
      );
    });

    test('CloudSyncResult clamps a negative count to zero', () {
      final report = CloudSyncResult.fromMap(const {
        'cloudReady': true,
        'movedRows': -3,
        'failed': false,
      });
      expect(report.movedRows, 0);
      expect(report.failed, isFalse);
    });
  });
}
