import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_data.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/mock_telemetry_store.dart';
import 'package:capy_energy/core/telemetry_api.dart';

/// The mock runs on web and under `CAPY_MOCK_TELEMETRY`, so nothing on the car
/// exercises it. Every method is called here, because a wrong argument key in
/// the mock's switch parses to a default and shows as a plausible-looking zero
/// in the browser rather than as a failure anywhere else.
void main() {
  late TelemetryApi api;

  setUp(
    () => api = TelemetryApi(
      source: MockTelemetrySource(),
      store: buildMockTelemetryStore(MockTelemetryData()),
    ),
  );

  test('every read answers something its DTO can parse', () async {
    await api.getPlatformStatus();
    await api.getTelemetrySnapshot();
    await api.getCollectorStatus();
    await api.getRoadcastStatus();
    await api.getAppUpdateStatus();
    await api.checkAppUpdate();
    await api.installAppUpdate();
    await api.getRoadcastUpdateStatus();
    await api.checkRoadcastUpdate();
    await api.updateRoadcastDaemon();
    await api.restartRoadcastDaemon();
    await api.getLiveTelemetrySnapshot();
    await api.getHvacControlStatus();
    await api.getLiveEnergyBuckets();
    await api.getLiveEfficiencyBuckets();
    await api.getRangeEstimate();
    await api.getTelemetrySettings();
    await api.getChargeMergeCandidates();
    await api.runTelemetryRetention();
    await api.clearTelemetryDatabase();
    await api.getEnergyBucketsInWindow(EnergyWindow.lastHour);
  });

  test('an argument reaches the mock instead of defaulting silently', () async {
    final events = await api.getTelemetryEvents(limit: 3);
    expect(events.events.length, lessThanOrEqualTo(3));

    final trips = await api.listSessions(
      filter: const SessionFilter(kind: SessionKind.trip),
      page: const PageRequest(limit: 2),
    );
    expect(trips.sessions.length, lessThanOrEqualTo(2));

    final insight = await api.getInsightTrips(
      subjectId: trips.sessions.last.id,
    );
    expect(insight.subjectId, trips.sessions.last.id);
    expect(insight.trips, isNotEmpty);

    expect((await api.getInsightPlaces()).places, isEmpty);
    final named = await api.saveInsightPlace(
      name: 'Home',
      latitude: -10.18,
      longitude: -48.33,
    );
    expect(named.name, 'Home');
    expect((await api.getInsightPlaces()).places, hasLength(1));

    final charges = await api.listSessions(
      filter: const SessionFilter(kind: SessionKind.charge),
      page: const PageRequest(limit: 2),
    );
    expect(charges.sessions.length, lessThanOrEqualTo(2));
  });

  test('a setting written comes back set', () async {
    expect((await api.setGpsEnabled(false)).gpsEnabled, isFalse);
    expect((await api.setGpsEnabled(true)).gpsEnabled, isTrue);
    expect((await api.setAutoStartOnBoot(true)).autoStartOnBoot, isTrue);
    expect(
      (await api.setDebugEventFileEnabled(true)).debugEventFileEnabled,
      isTrue,
    );
    expect(
      (await api.setTemperatureModeHelperEnabled(
        true,
      )).temperatureModeHelperEnabled,
      isTrue,
    );
    expect(
      (await api.setDefaultChargeCostPerKwh(1.25)).defaultChargeCostPerKwh,
      1.25,
    );
  });

  test(
    'hvac writes report what the mock applied, not what was asked',
    () async {
      final temperature = await api.setHvacTemperature(21.3);
      expect(temperature.appliedValue, 21.5);

      final fan = await api.setHvacFanSpeed(99);
      expect(fan.ok, isTrue);
      expect(fan.appliedValue, lessThan(99));

      expect((await api.stepHvacTemperature(0.5)).appliedValue, 22.5);
      expect((await api.stepHvacFanSpeed(1)).appliedValue, 4);
    },
  );

  test('the mock car answers the three questions like any store', () async {
    final trips = await api.listSessions(
      filter: const SessionFilter(kind: SessionKind.trip),
      page: const PageRequest(limit: 1),
    );
    final id = trips.sessions.first.id;

    final stored = await api.getSession(id);
    expect(stored, isNotNull);
    expect(stored!.session.id, id);

    final series = await api.getSeries(id);
    expect(series.sessionId, id);
    expect(series.intervals, isNotEmpty);

    final charges = await api.listSessions(
      filter: const SessionFilter(kind: SessionKind.charge),
      page: const PageRequest(limit: 1),
    );
    final chargeId = charges.sessions.first.id;
    expect((await api.getSession(chargeId))?.session.id, chargeId);
  });

  test('a method with no mock answer fails by name', () async {
    // The failure a missing case must produce: loud, and naming the method.
    expect(
      () => MockTelemetrySource().call('getSomethingNobodyMocked'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('getSomethingNobodyMocked'),
        ),
      ),
    );
  });
}
