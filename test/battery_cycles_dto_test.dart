import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/telemetry_api.dart';

/// The gates a generated wire class cannot carry.
///
/// The native ledger already refuses most of these, so the point here is that a
/// screen reading the DTO cannot reach a number the cycle does not support —
/// whichever side produced it.
void main() {
  Map<String, Object?> cycle({
    double dischargePercent = 100,
    double distanceKm = 400,
    double tripEnergyKwh = 39.6,
    double pricedEnergyKwh = 39.6,
    double unpricedEnergyKwh = 0,
    double? cost = 30.0,
    bool energyIncomplete = false,
    bool mixedCurrency = false,
    int? frozenAtUtcMillis,
  }) => {
    'ordinal': 1,
    'startUtcMillis': 1000,
    'endUtcMillis': 2000,
    'dischargePercent': dischargePercent,
    'distanceKm': distanceKm,
    'tripEnergyKwh': tripEnergyKwh,
    'parkedEnergyKwh': 0.0,
    'parkedSocPercent': 0.0,
    'pricedEnergyKwh': pricedEnergyKwh,
    'unpricedEnergyKwh': unpricedEnergyKwh,
    'isOpen': false,
    'isPartial': false,
    'energyIncomplete': energyIncomplete,
    'mixedCurrency': mixedCurrency,
    'updatedAtUtcMillis': 2000,
    'cost': cost,
    'costCurrency': 'BRL',
    'frozenAtUtcMillis': frozenAtUtcMillis,
  };

  test('a complete cycle reports both efficiency units and its price', () {
    final summary = BatteryCycleSummary.fromMap(cycle());

    expect(summary.hasEnergy, isTrue);
    expect(summary.kmPerKwh, closeTo(400 / 39.6, 1e-9));
    expect(summary.whPerKm, closeTo(39.6 * 1000 / 400, 1e-9));
    expect(summary.averageCostPerKwh, closeTo(30.0 / 39.6, 1e-9));
    expect(summary.costCoverage, 1.0);
    expect(summary.completeCost, 30.0);
  });

  test('an energy floor suppresses energy-derived readouts, not the bar', () {
    final summary = BatteryCycleSummary.fromMap(cycle(energyIncomplete: true));

    // The bar and the distance need no capacity, so they survive.
    expect(summary.dischargePercent, 100);
    expect(summary.distanceKm, 400);
    // Dividing a floor into a distance reports travel the car never achieved.
    expect(summary.hasEnergy, isFalse);
    expect(summary.kmPerKwh, isNull);
    expect(summary.whPerKm, isNull);
    expect(summary.measuredCapacityKwh, isNull);
  });

  test('two currencies leave the cycle with no cost at all', () {
    final summary = BatteryCycleSummary.fromMap(
      cycle(mixedCurrency: true, cost: 30.0),
    );

    expect(summary.cost, isNull);
    expect(summary.costCurrency, isNull);
    expect(summary.averageCostPerKwh, isNull);
    expect(summary.completeCost, isNull);
  });

  test('a part-priced cycle keeps its cost but is not a complete one', () {
    final summary = BatteryCycleSummary.fromMap(
      cycle(cost: 20.0, pricedEnergyKwh: 27.4, unpricedEnergyKwh: 12.2),
    );

    // The share that was paid for is a real figure and the average price of it
    // is readable. What it must not do is stand in for the whole cycle.
    expect(summary.cost, 20.0);
    expect(summary.averageCostPerKwh, closeTo(20.0 / 27.4, 1e-9));
    expect(summary.costCoverage, closeTo(27.4 / 39.6, 1e-9));
    expect(summary.completeCost, isNull);
  });

  test('measured capacity is the kWh the cycle drew per 100 % of SOC', () {
    final summary = BatteryCycleSummary.fromMap(
      cycle(dischargePercent: 50, tripEnergyKwh: 19.0),
    );

    expect(summary.measuredCapacityKwh, closeTo(38.0, 1e-9));
  });

  test('a nonsense row divides into nothing rather than into a number', () {
    final summary = BatteryCycleSummary.fromMap(
      cycle(dischargePercent: 140, distanceKm: -12, tripEnergyKwh: 0),
    );

    expect(summary.dischargePercent, 100);
    expect(summary.distanceKm, 0);
    expect(summary.kmPerKwh, isNull);
    expect(summary.whPerKm, isNull);
  });

  test('the mock answers the cycle list and names the open one', () async {
    final api = TelemetryApi(source: MockTelemetrySource());

    final result = await api.getBatteryCycles();

    expect(result.cycles, isNotEmpty);
    expect(result.totalCount, result.cycles.length);
    // Newest first, and at most one cycle is open.
    expect(
      result.cycles.map((c) => c.ordinal).toList(),
      orderedEquals(
        (result.cycles.map((c) => c.ordinal).toList()..sort()).reversed,
      ),
    );
    expect(result.cycles.where((c) => c.isOpen), hasLength(1));
    expect(result.openCycle, same(result.cycles.first));
  });

  test('the limit reaches the mock, so a short page is really short', () async {
    final api = TelemetryApi(source: MockTelemetrySource());

    final result = await api.getBatteryCycles(limit: 2);

    expect(result.cycles, hasLength(2));
    expect(result.limit, 2);
    // The count is the whole record, not the page.
    expect(result.totalCount, greaterThan(2));
  });

  test(
    'the mock answers what a cycle is made of, and a split trip says so',
    () async {
      final api = TelemetryApi(source: MockTelemetrySource());

      final result = await api.getBatteryCycleSessions(ordinal: 3);

      expect(result.ordinal, 3);
      expect(result.sessions, isNotEmpty);
      // Oldest first, and the drive the cycle closed inside carries its share.
      final starts = result.sessions
          .map((entry) => entry.startUtcMillis)
          .toList();
      expect(starts, orderedEquals([...starts]..sort()));
      final split = result.sessions.firstWhere((entry) => entry.isSplit);
      expect(split.kind, BatteryCycleSessionKind.trip);
      expect(split.share, closeTo(0.45, 1e-9));
      expect(split.isSplit, isTrue);
      expect(split.trip, isNotNull);
    },
  );

  test('a deleted session keeps its place, its id and its window', () async {
    final api = TelemetryApi(source: MockTelemetrySource());

    final result = await api.getBatteryCycleSessions(ordinal: 3);

    final deleted = result.sessions.firstWhere((entry) => entry.deleted);
    // The session is gone, so there is nothing to open. Dropping the member
    // would make a short list look like the whole one instead.
    expect(deleted.isReadable, isFalse);
    expect(deleted.sessionId, isNotEmpty);
    expect(deleted.endUtcMillis, greaterThan(deleted.startUtcMillis));
    expect(result.hasDeletedSessions, isTrue);
  });

  test(
    'a parked member carries no session row, and that is not a deletion',
    () async {
      final api = TelemetryApi(source: MockTelemetrySource());

      final result = await api.getBatteryCycleSessions(ordinal: 3);

      final parked = result.sessions.firstWhere(
        (entry) => entry.kind == BatteryCycleSessionKind.parked,
      );
      expect(parked.trip, isNull);
      expect(parked.charge, isNull);
      expect(parked.deleted, isFalse);
    },
  );

  test('a frozen cycle answers with no membership at all', () async {
    final api = TelemetryApi(source: MockTelemetrySource());

    // Its sessions were deleted before the membership was recorded, so there
    // is nothing to reconstruct and nothing to claim.
    final result = await api.getBatteryCycleSessions(ordinal: 1);

    expect(result.sessions, isEmpty);
    expect(result.hasDeletedSessions, isFalse);
  });

  test('an impossible member is refused rather than drawn', () {
    final entry = BatteryCycleSessionEntry.fromMap(const {
      'kind': 'TRIP',
      'sessionId': 'trip-1',
      // Not a share.
      'share': 4.0,
      'startUtcMillis': 1000,
      'endUtcMillis': 2000,
      // A member that arrived with its session cannot also be a deleted one.
      'deleted': true,
      'trip': {
        'id': 'trip-1',
        'status': 'ENDED',
        'startedAtUtcMillis': 1000,
        'endedAtUtcMillis': 2000,
      },
      // And a trip cannot carry a charge.
      'charge': {'id': 'charge-1', 'status': 'ENDED'},
    });

    expect(entry.share, 1.0);
    expect(entry.deleted, isFalse);
    expect(entry.trip, isNotNull);
    expect(entry.charge, isNull);
  });
}
