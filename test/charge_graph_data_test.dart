import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/charge_graph_data.dart';
import 'package:capy_energy/core/telemetry_api.dart';

import 'support/session_records.dart';

void main() {
  test('the slot grid sets the width of a medium charge', () {
    final graph = buildChargeGraphData(
      detail: _detail(durationMinutes: 108),
      duration: const Duration(minutes: 108),
    );

    expect(graph.intervalSeconds, 300);
    expect(graph.buckets, hasLength(22));
    expect(graph.axisMaximumKw, 80);
    expect(graph.buckets.last.endSeconds, 6480);
  });

  test('a short charge is plotted in minutes, not five-minute steps', () {
    final graph = buildChargeGraphData(
      detail: _detail(durationMinutes: 20),
      duration: const Duration(minutes: 20),
      capacity: 24,
    );

    expect(graph.intervalSeconds, 60);
    expect(graph.buckets, hasLength(20));
  });

  test('a twelve-hour charge stays within the readable bar limit', () {
    final graph = buildChargeGraphData(
      detail: _detail(durationMinutes: 720),
      duration: const Duration(hours: 12),
    );

    expect(graph.intervalSeconds, 1800);
    expect(graph.buckets, hasLength(24));
  });

  test('the charge bucket width adapts to the visible slot count', () {
    final graph = buildChargeGraphData(
      detail: _detail(durationMinutes: 108),
      duration: const Duration(minutes: 108),
      capacity: 10,
    );

    expect(graph.intervalSeconds, 11 * 60);
    expect(graph.buckets.length, lessThanOrEqualTo(10));
  });

  test('idle time after the limit is held, not left empty', () {
    final graph = buildChargeGraphData(
      detail: _reachedThenIdle(),
      duration: const Duration(minutes: 900),
      capacity: 30,
    );

    final held = graph.buckets.where((bucket) => bucket.isHeld).toList();
    expect(held, isNotEmpty);
    // No sample was recorded while the car slept, but the SOC is known to be
    // sitting still, so it is carried rather than dropped.
    expect(held.every((bucket) => bucket.socPercent != null), isTrue);
    expect(held.first.socPercent, closeTo(70, 0.5));
    // The curve closes at zero through the hold instead of breaking in
    // mid-air at the last kilowatt it measured.
    expect(held.every((bucket) => bucket.powerKw == 0), isTrue);
  });

  test('a bucket with no new samples carries forward the previous SOC', () {
    final graph = buildChargeGraphData(
      // One reading at each end of the hour and nothing between them.
      detail: _sparse(
        id: 'charge-gap',
        socByMinute: const {0: 40.0, 60: 50.0},
        powerByMinute: const {0: 3.0, 60: 3.0},
        spanMinutes: 60,
      ),
      duration: const Duration(hours: 1),
      capacity: 12,
    );

    // With delta/change-only telemetry, missing intermediate SOC samples are
    // carried forward from the previous minute so the bar chart has no gaps.
    expect(graph.buckets.every((bucket) => bucket.socPercent != null), isTrue);
    expect(graph.buckets.first.socPercent, 40.0);
    expect(graph.buckets[1].socPercent, 40.0);
    expect(graph.buckets.last.socPercent, 50.0);
  });

  test('the power curve reaches zero where charging stopped', () {
    final graph = buildChargeGraphData(
      detail: _reachedThenIdle(),
      duration: const Duration(minutes: 900),
      capacity: 30,
    );

    final buckets = graph.buckets;
    final firstHeld = buckets.indexWhere((bucket) => bucket.isHeld);
    expect(firstHeld, greaterThan(0));
    // The bucket before the hold still carries the charge it measured, and the
    // hold takes the curve to zero rather than dropping it.
    expect(buckets[firstHeld - 1].powerKw, greaterThan(0));
    expect(buckets[firstHeld].powerKw, 0);
  });

  test('the limit is reported on the plotted axis', () {
    final graph = buildChargeGraphData(
      detail: _reachedThenIdle(),
      duration: const Duration(minutes: 900),
      capacity: 30,
    );

    expect(graph.targetReachedSeconds, hasLength(1));
    expect(graph.targetReachedSeconds.single, 780 * 60.0);
  });

  test('a runaway idle tail is trimmed so the charge keeps the plot', () {
    // Same thirteen-hour charge, but left plugged in for three days.
    final graph = buildChargeGraphData(
      detail: _reachedThenIdle(),
      duration: const Duration(days: 3),
      capacity: 30,
    );

    expect(graph.truncatedTail, greaterThan(Duration.zero));
    // The charge still occupies most of the plot instead of a sliver.
    final charging = graph.buckets
        .where((bucket) => bucket.phase == ChargePhase.charging)
        .length;
    expect(charging / graph.buckets.length, greaterThan(0.5));
  });

  test('a session that never met its limit holds nothing', () {
    final graph = buildChargeGraphData(
      detail: _detail(durationMinutes: 108),
      duration: const Duration(minutes: 108),
    );

    expect(graph.targetReachedSeconds, isEmpty);
    expect(graph.buckets.any((bucket) => bucket.isHeld), isFalse);
  });

  test('a long charge can use a 32-minute bucket', () {
    final graph = buildChargeGraphData(
      detail: _detail(durationMinutes: 1152),
      duration: const Duration(minutes: 1152),
      capacity: 36,
    );

    expect(graph.intervalSeconds, 32 * 60);
    expect(graph.buckets, hasLength(36));
  });

  test('SOC uses the last sample and power uses the bucket mean', () {
    final graph = buildChargeGraphData(
      detail: _sparse(
        id: 'charge',
        socByMinute: const {0: 50.0, 4: 55.0},
        powerByMinute: const {0: 10.0, 4: 12.0},
        spanMinutes: 5,
      ),
      duration: const Duration(minutes: 5),
      capacity: 1,
    );

    expect(graph.buckets.single.socPercent, 55);
    expect(graph.buckets.single.powerKw, 11);
  });

  test('fixed power curve keeps 1 kW visible and 30 kW above 8 kW', () {
    expect(chargePowerPlotValue(0), 0);
    expect(chargePowerPlotValue(1), greaterThan(10));
    expect(chargePowerPlotValue(30), greaterThan(chargePowerPlotValue(8)));
    expect(chargePowerPlotValue(80), closeTo(100, 0.001));
  });

  test('a supplied window is authoritative over the series', () {
    // The window now runs plug-in to plug-out rather than stopping with the
    // charge, but it is still what bounds the plot: a caller that asks for a
    // shorter span gets it, and later samples are dropped rather than
    // stretching the axis.
    final detail = _detail(durationMinutes: 300);
    final full = buildChargeGraphData(detail: detail, duration: null);
    final charged = buildChargeGraphData(
      detail: detail,
      duration: const Duration(minutes: 120),
    );

    // Without a window the plot runs to the last sample; with one it stops
    // where the caller asked and the trailing samples are dropped.
    expect(full.buckets.last.endSeconds, closeTo(300 * 60, 0.001));
    expect(charged.buckets.last.endSeconds, closeTo(120 * 60, 0.001));
    // Every interval inside the charge window still carries its samples.
    expect(charged.buckets.every((b) => b.powerKw != null), isTrue);
    expect(charged.buckets.every((b) => b.socPercent != null), isTrue);
  });

  test('the shared ceiling holds for every session under it', () {
    // Two sessions at different powers must stay comparable by eye, so the
    // axis does not rescale to each one's own peak.
    final gentle = buildChargeGraphData(
      detail: _detail(durationMinutes: 60, powerKw: 3),
      duration: const Duration(minutes: 60),
    );
    final brisk = buildChargeGraphData(
      detail: _detail(durationMinutes: 60, powerKw: 70),
      duration: const Duration(minutes: 60),
    );

    expect(gentle.axisMaximumKw, chargeGraphMaximumPowerKw);
    expect(brisk.axisMaximumKw, chargeGraphMaximumPowerKw);
    expect(brisk.powerTicksKw, [80, 30, 10, 0]);
  });

  test('a session above the ceiling raises the axis instead of clamping', () {
    final graph = buildChargeGraphData(
      detail: _detail(durationMinutes: 60, powerKw: 143),
      duration: const Duration(minutes: 60),
    );

    // Clamping would have flattened 143 kW into the top gridline while the
    // tooltip still read the true figure.
    expect(graph.axisMaximumKw, 150);
    expect(graph.powerTicksKw, [150, 30, 10, 0]);
    expect(
      chargePowerPlotValue(143, ceilingKw: graph.axisMaximumKw),
      lessThan(100),
    );
    expect(
      chargePowerPlotValue(150, ceilingKw: graph.axisMaximumKw),
      closeTo(100, 0.001),
    );
  });
}

/// A charge of [durationMinutes], drawing [powerKw] the whole way.
///
/// Built as the store answers: one stored minute per minute of charge, and a
/// state-of-charge sample every three. The power on the chart is the energy of
/// a minute stated per hour, so a flat [powerKw] is a flat series.
ChargeDetailReading _detail({
  required int durationMinutes,
  double powerKw = 11.0,
}) {
  const start = 1785974064000;
  const startNanos = 1000000000;
  return ChargeDetailReading(
    session: chargeRecord(
      id: 'charge',
      startedAtUtcMillis: start,
      startedAtElapsedNanos: startNanos,
      plugDisconnectedAtUtcMillis: start + durationMinutes * 60000,
    ),
    series: TelemetrySeries(
      sessionId: 'charge',
      intervals: [
        for (var minute = 0; minute < durationMinutes; minute++)
          intervalRecord(
            sessionId: 'charge',
            startUtcMillis: start + minute * 60000,
            deliveredWh: powerKw * 1000 / 60,
            deliveredCoveredSeconds: 60,
            startSoc: 50 + minute / durationMinutes * 30,
            endSoc: 50 + (minute + 1) / durationMinutes * 30,
          ),
      ],
    ),
  );
}

/// The session captured on 2026-08-06: thirteen hours of AC charging, the limit
/// met at 70%, then two idle hours on the plug before it was unplugged.
ChargeDetailReading _reachedThenIdle({int chargeMinutes = 780}) {
  const start = 1785974064000;
  const startNanos = 1000000000;
  return ChargeDetailReading(
    session: chargeRecord(
      id: 'charge-reached',
      startedAtUtcMillis: start,
      startedAtElapsedNanos: startNanos,
      plugDisconnectedAtUtcMillis: start + (chargeMinutes + 120) * 60000,
    ),
    series: TelemetrySeries(
      sessionId: 'charge-reached',
      intervals: [
        for (var minute = 0; minute < chargeMinutes; minute++)
          intervalRecord(
            sessionId: 'charge-reached',
            startUtcMillis: start + minute * 60000,
            deliveredWh: 1.05 * 1000 / 60,
            deliveredCoveredSeconds: 60,
            startSoc: 42.7 + minute / chargeMinutes * 27.3,
            endSoc: 42.7 + (minute + 1) / chargeMinutes * 27.3,
          ),
      ],
    ),
    events: [
      TelemetryEventRecord(
        id: 1,
        sessionId: 'charge-reached',
        type: kChargeLimitReachedEvent,
        occurredAtUtcMillis: start + chargeMinutes * 60000,
        occurredAtElapsedNanos: startNanos + chargeMinutes * 60 * 1000000000,
      ),
    ],
  );
}

/// A charge stated minute by minute, from the two maps a test cares about.
///
/// A minute with no power named has no stored interval at all — a hole in the
/// record, which the chart must keep apart from a car sitting still.
ChargeDetailReading _sparse({
  required String id,
  required Map<int, double> socByMinute,
  required Map<int, double> powerByMinute,
  required int spanMinutes,
}) {
  const start = 1785974064000;
  const startNanos = 1000000000;
  return ChargeDetailReading(
    session: chargeRecord(
      id: id,
      startedAtUtcMillis: start,
      startedAtElapsedNanos: startNanos,
      plugDisconnectedAtUtcMillis: start + spanMinutes * 60000,
    ),
    series: TelemetrySeries(
      sessionId: id,
      intervals: [
        for (final entry in powerByMinute.entries)
          intervalRecord(
            sessionId: id,
            startUtcMillis: start + entry.key * 60000,
            deliveredWh: entry.value * 1000 / 60,
            deliveredCoveredSeconds: 60,
            startSoc: socByMinute[entry.key],
            endSoc: socByMinute[entry.key + 1] ?? socByMinute[entry.key],
          ),
      ],
    ),
  );
}
