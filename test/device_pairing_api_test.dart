import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_data.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/mock_telemetry_store.dart';
import 'package:capy_energy/core/telemetry_api.dart';

TelemetryApi _apiWithAnswer(
  Map<String, Object?>? Function(String method, Map<String, Object?> args)
  answer,
) => TelemetryApi(
  source: MockTelemetrySource(answer: answer),
  store: buildMockTelemetryStore(MockTelemetryData()),
);

void main() {
  group('DevicePairingState.fromMap', () {
    test('parses idle', () {
      final state = DevicePairingState.fromMap({'status': 'idle'});
      expect(state, isA<DevicePairingIdle>());
      expect((state as DevicePairingIdle).cancelled, isFalse);
      expect(state.status, 'idle');
    });

    test('parses idle with cancelled true from cancelDevicePairing', () {
      final state = DevicePairingState.fromMap({
        'status': 'idle',
        'cancelled': true,
      });
      expect(state, isA<DevicePairingIdle>());
      expect((state as DevicePairingIdle).cancelled, isTrue);
    });

    test('parses pending with all fields', () {
      final map = {
        'status': 'pending',
        'userCode': '482-910',
        'expiresAt': '2099-01-01T00:00:00.000Z',
        'vehicleId': 'unassigned',
      };
      final state = DevicePairingState.fromMap(map);
      expect(state, isA<DevicePairingPending>());
      final pending = state as DevicePairingPending;
      expect(pending.userCode, '482-910');
      expect(pending.expiresAt, '2099-01-01T00:00:00.000Z');
      expect(pending.vehicleId, 'unassigned');
      expect(pending.status, 'pending');
    });

    test('parses pending with null userCode/expiresAt (stale memory)', () {
      final map = {
        'status': 'pending',
        'userCode': null,
        'expiresAt': null,
        'vehicleId': '01HVEHICLE',
      };
      final state = DevicePairingState.fromMap(map);
      expect(state, isA<DevicePairingPending>());
      final pending = state as DevicePairingPending;
      expect(pending.userCode, isNull);
      expect(pending.expiresAt, isNull);
      expect(pending.vehicleId, '01HVEHICLE');
    });

    test('parses approved', () {
      final map = {
        'status': 'approved',
        'vehicleId': '01HVEHICLE',
        'accountId': '00000000-0000-4000-a000-000000000001',
      };
      final state = DevicePairingState.fromMap(map);
      expect(state, isA<DevicePairingApproved>());
      final approved = state as DevicePairingApproved;
      expect(approved.vehicleId, '01HVEHICLE');
      expect(approved.accountId, '00000000-0000-4000-a000-000000000001');
      expect(approved.cancelled, isFalse);
    });

    test('parses approved with cancelled true', () {
      final map = {
        'status': 'approved',
        'vehicleId': '01HVEHICLE',
        'accountId': 'acct-1',
        'cancelled': true,
      };
      final state = DevicePairingState.fromMap(map);
      expect(state, isA<DevicePairingApproved>());
      expect((state as DevicePairingApproved).cancelled, isTrue);
    });

    test('parses expired', () {
      final state = DevicePairingState.fromMap({
        'status': 'expired',
        'reason': 'expired',
      });
      expect(state, isA<DevicePairingExpired>());
      expect((state as DevicePairingExpired).reason, 'expired');
    });

    test('parses rejected distinct from expired', () {
      final expired = DevicePairingState.fromMap({
        'status': 'expired',
        'reason': 'expired',
      });
      final rejected = DevicePairingState.fromMap({
        'status': 'rejected',
        'reason': 'rejected',
      });
      expect(expired, isA<DevicePairingExpired>());
      expect(rejected, isA<DevicePairingRejected>());
      expect(expired.runtimeType, isNot(equals(rejected.runtimeType)));
      expect((rejected as DevicePairingRejected).reason, 'rejected');
    });

    test('parses invalidCode', () {
      final state = DevicePairingState.fromMap({
        'status': 'invalidCode',
        'reason': 'invalid_code',
      });
      expect(state, isA<DevicePairingInvalidCode>());
      expect((state as DevicePairingInvalidCode).reason, 'invalid_code');
    });

    test('parses revoked', () {
      final state = DevicePairingState.fromMap({
        'status': 'revoked',
        'reason': 'revoked',
      });
      expect(state, isA<DevicePairingRevoked>());
      expect((state as DevicePairingRevoked).reason, 'revoked');
      expect(state.status, 'revoked');
    });

    test('malformed returns null', () {
      expect(DevicePairingState.fromMap(null), isNull);
      expect(DevicePairingState.fromMap({}), isNull);
      expect(DevicePairingState.fromMap({'status': 'unknown'}), isNull);
      expect(
        DevicePairingState.fromMap({'status': 'idle', 'cancelled': 'not-bool'}),
        isA<DevicePairingIdle>(),
      ); // bool fallback
      expect(
        DevicePairingState.fromMap({'status': 'pending'}),
        isNull,
      ); // missing vehicleId
      expect(
        DevicePairingState.fromMap({
          'status': 'pending',
          'vehicleId': '',
          'userCode': '123',
          'expiresAt': 'now',
        }),
        isNull,
      ); // empty vehicleId
      expect(
        DevicePairingState.fromMap({'status': 'approved', 'vehicleId': 'v1'}),
        isNull,
      ); // missing accountId
      expect(
        DevicePairingState.fromMap({'status': 'expired'}),
        isNull,
      ); // missing reason
      expect(
        DevicePairingState.fromMap({'status': 'rejected', 'reason': ''}),
        isNull,
      );
      expect(
        DevicePairingState.fromMap({'status': 'invalidCode', 'reason': null}),
        isNull,
      );
    });

    test('value equality', () {
      const a = DevicePairingIdle();
      const b = DevicePairingIdle();
      expect(a, equals(b));
      const c = DevicePairingIdle(cancelled: true);
      expect(a, isNot(equals(c)));
      const p1 = DevicePairingPending(
        vehicleId: 'v1',
        userCode: '111-222',
        expiresAt: '2099-01-01T00:00:00.000Z',
      );
      const p2 = DevicePairingPending(
        vehicleId: 'v1',
        userCode: '111-222',
        expiresAt: '2099-01-01T00:00:00.000Z',
      );
      expect(p1, equals(p2));
    });

    test('switch on sealed is exhaustive', () {
      DevicePairingState state = const DevicePairingRejected(
        reason: 'rejected',
      );
      final label = switch (state) {
        DevicePairingIdle() => 'idle',
        DevicePairingPending() => 'pending',
        DevicePairingApproved() => 'approved',
        DevicePairingRegistered() => 'registered',
        DevicePairingExpired() => 'expired',
        DevicePairingRejected() => 'rejected',
        DevicePairingInvalidCode() => 'invalidCode',
        DevicePairingRevoked() => 'revoked',
      };
      expect(label, 'rejected');
    });

    test('parses registered', () {
      final state = DevicePairingState.fromMap({
        'status': 'registered',
        'reason': 'registered',
      });
      expect(state, isA<DevicePairingRegistered>());
      expect(state!.status, 'registered');
    });
  });

  group('TelemetryApi device pairing bridge', () {
    test('startDevicePairing parses pending', () async {
      final api = _apiWithAnswer((method, _) {
        if (method == 'startDevicePairing') {
          return {
            'status': 'pending',
            'userCode': '482-910',
            'expiresAt': '2099-01-01T00:00:00.000Z',
            'vehicleId': '01HVEHICLE',
          };
        }
        return null;
      });
      final state = await api.startDevicePairing();
      expect(state, isA<DevicePairingPending>());
      final pending = state as DevicePairingPending;
      expect(pending.userCode, '482-910');
    });

    test('startDevicePairing throws on malformed map', () async {
      final api = _apiWithAnswer((method, _) {
        if (method == 'startDevicePairing') {
          return {'status': 'pending'}; // missing vehicleId
        }
        return null;
      });
      expect(
        () => api.startDevicePairing(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('startDevicePairing returned an invalid state'),
          ),
        ),
      );
    });

    test('getDevicePairingState returns idle', () async {
      final api = _apiWithAnswer((method, _) {
        if (method == 'getDevicePairingState') return {'status': 'idle'};
        return null;
      });
      final state = await api.getDevicePairingState();
      expect(state, isA<DevicePairingIdle>());
    });

    test('getDevicePairingState returns pending', () async {
      final api = _apiWithAnswer((method, _) {
        if (method == 'getDevicePairingState') {
          return {
            'status': 'pending',
            'userCode': '482-910',
            'expiresAt': '2099-01-01T00:00:00.000Z',
            'vehicleId': '01HVEHICLE',
          };
        }
        return null;
      });
      final state = await api.getDevicePairingState();
      expect(state, isA<DevicePairingPending>());
    });

    test('getDevicePairingState returns approved', () async {
      final api = _apiWithAnswer((method, _) {
        if (method == 'getDevicePairingState') {
          return {
            'status': 'approved',
            'vehicleId': '01HVEHICLE',
            'accountId': 'acct-123',
          };
        }
        return null;
      });
      final state = await api.getDevicePairingState();
      expect(state, isA<DevicePairingApproved>());
      expect((state as DevicePairingApproved).accountId, 'acct-123');
    });

    test('getDevicePairingState returns expired', () async {
      final api = _apiWithAnswer((method, _) {
        if (method == 'getDevicePairingState') {
          return {'status': 'expired', 'reason': 'expired'};
        }
        return null;
      });
      final state = await api.getDevicePairingState();
      expect(state, isA<DevicePairingExpired>());
    });

    test('getDevicePairingState returns rejected', () async {
      final api = _apiWithAnswer((method, _) {
        if (method == 'getDevicePairingState') {
          return {'status': 'rejected', 'reason': 'rejected'};
        }
        return null;
      });
      final state = await api.getDevicePairingState();
      expect(state, isA<DevicePairingRejected>());
      expect((state as DevicePairingRejected).reason, 'rejected');
    });

    test('getDevicePairingState returns invalidCode', () async {
      final api = _apiWithAnswer((method, _) {
        if (method == 'getDevicePairingState') {
          return {'status': 'invalidCode', 'reason': 'invalid_code'};
        }
        return null;
      });
      final state = await api.getDevicePairingState();
      expect(state, isA<DevicePairingInvalidCode>());
    });

    test(
      'getDevicePairingState returns null when native returns null',
      () async {
        final fake = _NullReturningSource();
        final nullApi = TelemetryApi(
          source: fake,
          store: buildMockTelemetryStore(MockTelemetryData()),
        );
        final state = await nullApi.getDevicePairingState();
        expect(state, isNull);
      },
    );

    test('getDevicePairingState throws on malformed', () async {
      final api = _apiWithAnswer((method, _) {
        if (method == 'getDevicePairingState') {
          return {'status': 'approved', 'vehicleId': 'v1'}; // missing accountId
        }
        return null;
      });
      expect(
        () => api.getDevicePairingState(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('getDevicePairingState returned an invalid state'),
          ),
        ),
      );
    });

    test('cancelDevicePairing returns idle with cancelled', () async {
      final api = _apiWithAnswer((method, _) {
        if (method == 'cancelDevicePairing') {
          return {'status': 'idle', 'cancelled': true};
        }
        return null;
      });
      final state = await api.cancelDevicePairing();
      expect(state, isA<DevicePairingIdle>());
      expect((state as DevicePairingIdle).cancelled, isTrue);
    });

    test('cancelDevicePairing returns approved with cancelled', () async {
      final api = _apiWithAnswer((method, _) {
        if (method == 'cancelDevicePairing') {
          return {
            'status': 'approved',
            'vehicleId': '01HVEHICLE',
            'accountId': 'acct-123',
            'cancelled': true,
          };
        }
        return null;
      });
      final state = await api.cancelDevicePairing();
      expect(state, isA<DevicePairingApproved>());
      expect((state as DevicePairingApproved).cancelled, isTrue);
    });

    test('cancelDevicePairing throws on malformed', () async {
      final api = _apiWithAnswer((method, _) {
        if (method == 'cancelDevicePairing') {
          return {'status': 'idle', 'cancelled': true, 'garbage': 123};
        }
        return null;
      });
      // this one is actually valid idle + cancelled, should not throw
      final ok = await api.cancelDevicePairing();
      expect(ok, isA<DevicePairingIdle>());

      final badApi = _apiWithAnswer((method, _) {
        if (method == 'cancelDevicePairing') return {'garbage': true};
        return null;
      });
      expect(() => badApi.cancelDevicePairing(), throwsA(isA<StateError>()));
    });
  });
}

class _NullReturningSource implements TelemetrySource {
  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => throw StateError('unexpected call $method');

  @override
  Future<Map<String, Object?>?> callOrNull(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => null;

  @override
  Stream<Map<String, Object?>> liveFrames() => const Stream.empty();

  @override
  Stream<SessionChange> sessionChanges() => const Stream.empty();

  @override
  Stream<AnnotationChange> annotationsChanged() => const Stream.empty();

  @override
  Future<StorageUsage> storageUsage() async =>
      const StorageUsage(bytes: 0, databaseBytes: 0, walBytes: 0, shmBytes: 0);

  @override
  Future<List<Map<String, Object?>>> eventsForSession(String sessionId) async =>
      const [];

  @override
  Future<EnergyWindowBucketsResult> energyBucketsInWindow(int minutes) async =>
      EnergyWindowBucketsResult.fromWire(await Future.value(null) as dynamic);

  @override
  Future<EnergyWindowBucketsResult> parkedEnergyBucketsInWindow(
    int minutes,
  ) async => throw UnimplementedError();

  @override
  Future<LiveEnergyBucketsResult> liveEnergyBuckets() async =>
      throw UnimplementedError();
  @override
  Future<LiveEnergyBucketsResult> liveEfficiencyBuckets() async =>
      throw UnimplementedError();
  @override
  Future<LiveEnergyBucketsResult> liveChargeEnergyBuckets() async =>
      throw UnimplementedError();
  @override
  Future<LiveEnergyBucketsResult> liveContinuousEnergyBuckets() async =>
      throw UnimplementedError();
  @override
  Future<RangeEstimate> rangeEstimate() async => throw UnimplementedError();
  @override
  Future<HeadingReading> heading() async => throw UnimplementedError();
  @override
  Future<BatteryCyclesResult> batteryCycles(int limit) async =>
      throw UnimplementedError();
  @override
  Future<BatteryCycleSessionsResult> batteryCycleSessions(int ordinal) async =>
      throw UnimplementedError();
  @override
  Future<InsightTripsResult> insightTrips(String? subjectId) async =>
      throw UnimplementedError();
  @override
  Future<InsightPlacesResult> insightPlaces() async =>
      throw UnimplementedError();
  @override
  Future<InsightPlace> saveInsightPlace({
    String? id,
    required String name,
    required double latitude,
    required double longitude,
    double radiusM = 150,
    String? autoName,
    int? autoNameUpdatedAtUtcMillis,
    String? autoNameSource,
  }) async => throw UnimplementedError();
  @override
  Future<void> deleteInsightPlace(String id) async =>
      throw UnimplementedError();
  @override
  Future<ChargeMergeCandidatesResult> chargeMergeCandidates(int limit) async =>
      throw UnimplementedError();
  @override
  Future<ChargeMergeResult> mergeChargeSessions(
    List<String> sessionIds,
  ) async => throw UnimplementedError();
  @override
  Future<ChargeSessionCostUpdateResult> updateChargeSessionCost({
    required String sessionId,
    required double? costPerKwh,
    required double? paidAmount,
    required String currency,
  }) async => throw UnimplementedError();
  @override
  Future<List<PreferenceRow>> preferenceRows() async =>
      throw UnimplementedError();
  @override
  Future<PreferenceRow?> savePreferenceRow({
    required String scope,
    required String key,
    String? value,
  }) async => throw UnimplementedError();
  @override
  Future<List<PreferenceProposal>> preferenceProposals() async =>
      throw UnimplementedError();
  @override
  Future<PreferenceProposal?> proposePreference({
    required String key,
    String? value,
  }) async => throw UnimplementedError();
  @override
  Future<PreferenceProposal?> decidePreferenceProposal({
    required String id,
    required bool accept,
  }) async => throw UnimplementedError();
}
