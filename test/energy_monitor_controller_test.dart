import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/energy_monitor_controller.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/mock_telemetry_store.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_ui/capy_ui.dart';

final _base = DateTime(2026, 8, 3, 13);

const _emptyRollup = SessionRollup(
  distance: Measurement.unreported(unit: 'km'),
  traction: Measurement.unreported(unit: 'Wh'),
  regen: Measurement.unreported(unit: 'Wh'),
  auxiliary: Measurement.unreported(unit: 'Wh'),
  climate: Measurement.unreported(unit: 'Wh'),
  delivered: Measurement.unreported(unit: 'Wh'),
  integratedSeconds: Measurement.unreported(unit: 's'),
);

SessionRecord _sessionRecordFromSpan(SessionSpan span) => SessionRecord(
  id: 'span-${span.start.millisecondsSinceEpoch}',
  vehicleId: 'v',
  kind: span.kind,
  status: span.end == null ? 'OPEN' : 'CLOSED',
  startedAtUtcMillis: span.start.millisecondsSinceEpoch,
  startedAtElapsedNanos: 0,
  endedAtUtcMillis: span.end?.millisecondsSinceEpoch,
  rollup: _emptyRollup,
  startOdometer: const Measurement.unreported(unit: 'km'),
  endOdometer: const Measurement.unreported(unit: 'km'),
  startSoc: const Measurement.unreported(unit: '%'),
  endSoc: const Measurement.unreported(unit: '%'),
  minSoc: const Measurement.unreported(unit: '%'),
  maxSoc: const Measurement.unreported(unit: '%'),
  startAmbientTemp: const Measurement.unreported(unit: '°C'),
  endAmbientTemp: const Measurement.unreported(unit: '°C'),
  meanAmbientTemp: const Measurement.unreported(unit: '°C'),
  createdAtUtcMillis: span.start.millisecondsSinceEpoch,
  updatedAtUtcMillis: span.start.millisecondsSinceEpoch,
  sleepSeconds: span.sleepSeconds,
  sleepSocDeltaPercent: span.sleepSocDeltaPercent,
  sleepEnergyWhEstimate: span.sleepEnergyWhEstimate,
);

EnergyBucket _minute(
  int minute, {
  double traction = 60,
  double regenerated = 0,
  double auxiliary = 6,
  double seconds = 60,
}) => EnergyBucket(
  start: _base.add(Duration(minutes: minute)),
  width: EnergyBucket.oneMinute,
  tractionWh: traction,
  regeneratedWh: regenerated,
  auxiliaryWh: auxiliary,
  integratedSeconds: seconds,
);

/// One stored minute, as the store returns it.
IntervalRecord _interval(String sessionId, EnergyBucket bucket) =>
    IntervalRecord(
      sessionId: sessionId,
      startUtcMillis: bucket.start.millisecondsSinceEpoch,
      widthMillis: bucket.width.inMilliseconds,
      traction: Measurement.measured(bucket.tractionWh, unit: 'Wh'),
      regen: Measurement.measured(bucket.regeneratedWh, unit: 'Wh'),
      auxiliary: Measurement.measured(bucket.auxiliaryWh, unit: 'Wh'),
      climate: Measurement.measured(bucket.climateWh, unit: 'Wh'),
      delivered: Measurement.measured(bucket.deliveredWh, unit: 'Wh'),
      distance: Measurement.measured(bucket.speedDistanceKm, unit: 'km'),
      coveredSeconds: bucket.integratedSeconds,
      climateCoveredSeconds: bucket.climateIntegratedSeconds,
      speedCoveredSeconds: bucket.speedIntegratedSeconds,
      deliveredCoveredSeconds: 0,
      startSoc: bucket.startSoc == null
          ? const Measurement.unreported(unit: '%')
          : Measurement.measured(bucket.startSoc!, unit: '%'),
      endSoc: bucket.endSoc == null
          ? const Measurement.unreported(unit: '%')
          : Measurement.measured(bucket.endSoc!, unit: '%'),
    );

/// Wide enough for thirty bars, which is the reference slot budget.
final _chartWidth =
    AppSizes.chartAxisGutter + 30 * AppSizes.chartBarProfile.pitch;

class _FakeTelemetryApi extends TelemetryApi {
  /// A fake still needs a source and a store named. Without them it inherits
  /// the channel source, whose session-change stream reaches a real
  /// `EventChannel`, and the Room store, which reaches a real Pigeon channel.
  _FakeTelemetryApi()
    : super(source: MockTelemetrySource(), store: MockTelemetryStore());

  String? liveSessionId;
  List<EnergyBucket> live = const [];
  List<EnergyBucket> tripBuckets = const [];
  List<EnergyBucket> windowBuckets = const [];
  List<EnergyBucket> parkedBuckets = const [];
  DateTime windowStart = _base;

  bool failLive = false;
  bool failStored = false;

  /// The car's session-change push, driven by the test.
  final sessions = StreamController<SessionChange>.broadcast();

  @override
  Stream<SessionChange> sessionChanges() => sessions.stream;

  int tripReads = 0;
  int windowReads = 0;
  int parkedReads = 0;
  int liveReads = 0;
  String? lastTripSessionId;
  EnergyWindow? lastWindow;

  @override
  Future<LiveEnergyBucketsResult> getLiveEnergyBuckets() async {
    liveReads++;
    if (failLive) throw StateError('live unavailable');
    return LiveEnergyBucketsResult(
      sessionId: liveSessionId,
      startedAt: live.isEmpty ? null : live.first.start,
      buckets: live,
    );
  }

  /// The store's third question, over the minutes this fake holds.
  ///
  /// Both `currentDrive` and `sincePowerOn` read a session through this same
  /// method, exactly as the real store does: the interval table is keyed by
  /// session id alone. The fake tells them apart by which session id was
  /// last reported live, the way two real sessions never share an id.
  @override
  Future<TelemetrySeries> getSeries(
    String id, {
    Set<String>? keys,
    int? widthMillis,
  }) async {
    if (id == liveContinuousSessionId) {
      lastContinuousSessionId = id;
      if (failStored) throw StateError('database unavailable');
      return TelemetrySeries(
        sessionId: id,
        intervals: [
          for (final bucket in continuousBuckets) _interval(id, bucket),
        ],
        samples: const {},
      );
    }
    tripReads++;
    lastTripSessionId = id;
    if (failStored) throw StateError('database unavailable');
    return TelemetrySeries(
      sessionId: id,
      intervals: [for (final bucket in tripBuckets) _interval(id, bucket)],
      samples: const {},
    );
  }

  @override
  Future<SessionListPage> listSessions({
    SessionFilter? filter,
    PageRequest? page,
  }) async {
    final records = [
      for (final span in sessionSpans) _sessionRecordFromSpan(span),
    ];
    return SessionListPage(
      sessions: records,
      totalCount: records.length,
      page: page ?? const PageRequest(),
      hasMore: false,
    );
  }

  @override
  Future<EnergyWindowBucketsResult> getEnergyBucketsInWindow(
    EnergyWindow window,
  ) async {
    windowReads++;
    lastWindow = window;
    if (failStored) throw StateError('database unavailable');
    return EnergyWindowBucketsResult(
      start: windowStart,
      end: windowStart.add(Duration(minutes: window.minutes!)),
      buckets: windowBuckets,
    );
  }

  @override
  Future<EnergyWindowBucketsResult> getParkedEnergyBucketsInWindow(
    EnergyWindow window,
  ) async {
    parkedReads++;
    if (failStored) throw StateError('database unavailable');
    return EnergyWindowBucketsResult(
      start: windowStart,
      end: windowStart.add(Duration(minutes: window.minutes!)),
      buckets: parkedBuckets,
    );
  }

  // --- CONTINUOUS mode (issue 199/207) --------------------------------

  bool continuousModeEnabled = false;
  String? liveContinuousSessionId;
  List<EnergyBucket> liveContinuous = const [];
  List<EnergyBucket> continuousBuckets = const [];
  int continuousLiveReads = 0;
  String? lastContinuousSessionId;

  @override
  Future<TelemetrySettingsResult> getTelemetrySettings() async {
    return TelemetrySettingsResult(
      autoStartOnBoot: true,
      gpsEnabled: false,
      keepBluetoothOn: false,
      debugEventFileEnabled: false,
      temperatureModeHelperEnabled: false,
      replaceOemChargingEnabled: false,
      continuousModeEnabled: continuousModeEnabled,
      defaultChargeCostPerKwh: null,
      packCapacityWh: kDefaultPackCapacityWh,
      chargeCostCurrency: 'BRL',
    );
  }

  @override
  Future<LiveEnergyBucketsResult> getLiveContinuousEnergyBuckets() async {
    continuousLiveReads++;
    return LiveEnergyBucketsResult(
      sessionId: liveContinuousSessionId,
      startedAt: liveContinuousSessionId == null
          ? null
          : (liveContinuous.isNotEmpty
                ? liveContinuous.first.start
                : (continuousBuckets.isNotEmpty
                      ? continuousBuckets.first.start
                      : _base)),
      buckets: liveContinuous,
    );
  }

  List<SessionSpan> sessionSpans = const [];
}

/// A minute the car spent standing still: no traction, nothing returned.
EnergyBucket _parkedMinute(
  int minute, {
  double auxiliary = 2,
  double climate = 0,
  double climateSeconds = 60,
  double seconds = 60,
}) => EnergyBucket(
  start: _base.add(Duration(minutes: minute)),
  width: EnergyBucket.oneMinute,
  tractionWh: 0,
  regeneratedWh: 0,
  auxiliaryWh: auxiliary,
  integratedSeconds: seconds,
  climateWh: climate,
  climateIntegratedSeconds: climateSeconds,
);

void main() {
  group('sources', () {
    test('the live minutes are merged onto the stored ones', () async {
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [_minute(0), _minute(1, seconds: 20, traction: 20)]
        ..live = [_minute(1, seconds: 47, traction: 47)];

      final controller = EnergyMonitorController(telemetryApi: api);
      await controller.refresh();

      // The database was written partway through that minute; memory has more
      // of it, so the merged series takes memory's reading.
      expect(controller.minutes, hasLength(2));
      expect(controller.minutes.last.tractionWh, 47);
      controller.dispose();
    });

    test('the live poll runs far more often than the stored read', () async {
      // The live read is memory-only and is what makes the open bar grow. The
      // stored read sweeps sessions, so it waits for a bucket boundary.
      final api = _FakeTelemetryApi()..liveSessionId = 'trip-1';
      final controller = EnergyMonitorController(
        telemetryApi: api,
        livePollInterval: const Duration(milliseconds: 10),
        storedReloadInterval: const Duration(milliseconds: 200),
      );

      controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      controller.stop();

      expect(api.liveReads, greaterThan(5));
      expect(api.tripReads, lessThan(api.liveReads));
      expect(controller.isPolling, isFalse);
      controller.dispose();
    });

    test(
      'stop freezes the live poll so a hidden tab does not keep reading',
      () async {
        final api = _FakeTelemetryApi()..liveSessionId = 'trip-1';
        final controller = EnergyMonitorController(
          telemetryApi: api,
          livePollInterval: const Duration(milliseconds: 10),
          storedReloadInterval: const Duration(hours: 1),
        );

        controller.start();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(controller.isPolling, isTrue);
        final readsAtStop = api.liveReads;
        controller.stop();
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(controller.isPolling, isFalse);
        expect(api.liveReads, readsAtStop);
        controller.dispose();
      },
    );

    test(
      'pausing the activity freezes the live poll without stopping it',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        addTearDown(() {
          TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        });

        final api = _FakeTelemetryApi()..liveSessionId = 'trip-1';
        final controller = EnergyMonitorController(
          telemetryApi: api,
          livePollInterval: const Duration(milliseconds: 10),
          storedReloadInterval: const Duration(hours: 1),
        );

        controller.start();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(controller.isPolling, isTrue);
        final readsAtPause = api.liveReads;

        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.paused,
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(controller.isPolling, isTrue);
        expect(api.liveReads, readsAtPause);

        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(api.liveReads, greaterThan(readsAtPause));
        controller.dispose();
      },
    );

    test('a trip starting re-reads the current drive without waiting', () async {
      // A new trip changes what `currentDrive` refers to, so it cannot wait out
      // the slow tick showing the previous drive.
      final api = _FakeTelemetryApi();
      final controller = EnergyMonitorController(telemetryApi: api);

      await controller.refresh();
      final before = api.tripReads;

      api.liveSessionId = 'trip-2';
      await controller.refresh();

      expect(api.tripReads, greaterThan(before));
      expect(api.lastTripSessionId, 'trip-2');
      controller.dispose();
    });

    test('pricing a charge re-reads what the window cost', () async {
      // The rate this chart reports is not its own: the car scores a trip at
      // the rate of the last charge priced before it. Pricing a charge
      // therefore changes what the window on screen cost, and waiting a minute
      // to find out leaves a figure the reader has already corrected.
      final api = _FakeTelemetryApi()..liveSessionId = 'trip-1';
      addTearDown(() => api.sessions.close());
      final controller = EnergyMonitorController(telemetryApi: api);

      controller.start();
      await Future<void>.delayed(Duration.zero);
      final before = api.tripReads;

      api.sessions.add(
        const SessionChange(revision: 1, trips: false, charges: true),
      );
      await Future<void>.delayed(Duration.zero);

      expect(api.tripReads, greaterThan(before));
      controller.stop();
      controller.dispose();
    });

    test('a failed stored read keeps the series it already drew', () async {
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [_minute(0), _minute(1)];

      final controller = EnergyMonitorController(telemetryApi: api);
      await controller.refresh();
      expect(controller.minutes, hasLength(2));

      api.failStored = true;
      await controller.refresh();

      // An unreachable bridge is not a car that did not drive. The chart keeps
      // what it read, and `hasFailed` is what tells the two apart.
      expect(controller.minutes, hasLength(2));
      expect(controller.hasFailed, isTrue);
      controller.dispose();
    });

    test('a dropped live tick does not clear the stored series', () async {
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [_minute(0), _minute(1)]
        ..live = [_minute(1)];

      final controller = EnergyMonitorController(telemetryApi: api);
      await controller.refresh();
      expect(controller.minutes, hasLength(2));

      api.failLive = true;
      await controller.refresh();

      // One failed fast poll is a dropped tick, not a broken screen.
      expect(controller.minutes, hasLength(2));
      expect(controller.hasFailed, isFalse);
      controller.dispose();
    });

    test(
      'a failed stored read is reported, not shown as an empty trip',
      () async {
        final api = _FakeTelemetryApi()
          ..liveSessionId = 'trip-1'
          ..failStored = true;

        final controller = EnergyMonitorController(telemetryApi: api);
        await controller.refresh();

        expect(controller.hasFailed, isTrue);
        expect(controller.isLoading, isFalse);
        controller.dispose();
      },
    );

    test(
      'no trip running leaves the current drive empty, not failed',
      () async {
        final api = _FakeTelemetryApi()..liveSessionId = null;
        final controller = EnergyMonitorController(telemetryApi: api);

        await controller.refresh();

        expect(controller.activeSessionId, isNull);
        expect(controller.minutes, isEmpty);
        expect(controller.hasFailed, isFalse);
        expect(api.tripReads, 0);
        controller.dispose();
      },
    );
  });

  group('window selection', () {
    test('switching windows clears the previous answer', () async {
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [_minute(0), _minute(1)];

      final controller = EnergyMonitorController(telemetryApi: api);
      await controller.refresh();
      expect(controller.minutes, isNotEmpty);

      controller.selectWindow(EnergyWindow.lastHour);

      // Synchronously cleared: the old series is a different question's answer,
      // not a stale version of this one, so it must not sit under the new label
      // while the read is in flight.
      expect(controller.isLoading, isTrue);
      expect(controller.window, EnergyWindow.lastHour);
      controller.dispose();
    });

    test('a clock window is read by span, not by session', () async {
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..windowBuckets = [_minute(0), _minute(1)];

      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.last8Hours);
      await controller.refresh();

      expect(api.lastWindow, EnergyWindow.last8Hours);
      expect(api.tripReads, 0);
      controller.dispose();
    });

    test('an answer arriving after the window changed is discarded', () async {
      // Otherwise the slower of two in-flight reads wins and the chart settles
      // on the window the user already moved off.
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [_minute(0)]
        ..windowBuckets = [_minute(0), _minute(1), _minute(2)];

      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.lastHour);
      await controller.refresh();

      expect(controller.minutes, hasLength(3));
      controller.dispose();
    });
  });

  group('resolving to a chart', () {
    test(
      'a live chart reserves every visible slot from the first bucket',
      () async {
        final api = _FakeTelemetryApi()
          ..liveSessionId = 'trip-1'
          ..tripBuckets = [for (var i = 0; i < 12; i++) _minute(i)];

        final controller = EnergyMonitorController(
          telemetryApi: api,
          now: () => _base.add(const Duration(minutes: 11, seconds: 30)),
        );
        await controller.refresh();

        final series = controller.seriesForChartWidth(
          _chartWidth,
          capacity: AppSizes.chartBarProfile.slotsIn(
            _chartWidth - AppSizes.chartAxisGutter,
          ),
        );
        expect(series.buckets, hasLength(30));
        expect(
          series.buckets.take(12).every((bucket) => !bucket.isEmpty),
          isTrue,
        );
        expect(
          series.buckets.skip(12).every((bucket) => bucket.isEmpty),
          isTrue,
        );
        expect(series.buckets.first.start, _base);
        expect(series.buckets.last.end, _base.add(const Duration(minutes: 30)));
        controller.dispose();
      },
    );

    test(
      'a historical chart preserves leading and trailing empty slots',
      () async {
        final api = _FakeTelemetryApi()
          ..liveSessionId = null
          ..windowStart = _base
          ..windowBuckets = [_minute(10), _minute(11)];

        final controller = EnergyMonitorController(telemetryApi: api);
        controller.selectWindow(EnergyWindow.lastHour);
        await controller.refresh();

        final series = controller.seriesForChartWidth(
          _chartWidth,
          capacity: AppSizes.chartBarProfile.slotsIn(
            _chartWidth - AppSizes.chartAxisGutter,
          ),
        );
        expect(series.width, const Duration(minutes: 2));
        expect(series.buckets, hasLength(30));
        expect(
          series.buckets.take(5).every((bucket) => bucket.isEmpty),
          isTrue,
        );
        expect(series.buckets[5].isEmpty, isFalse);
        expect(
          series.buckets.skip(6).every((bucket) => bucket.isEmpty),
          isTrue,
        );
        expect(series.buckets.first.start, _base);
        expect(series.buckets.last.end, _base.add(const Duration(hours: 1)));
        controller.dispose();
      },
    );

    test(
      'a live chart rebuckets when its final slot becomes complete',
      () async {
        final api = _FakeTelemetryApi()
          ..liveSessionId = 'trip-1'
          ..tripBuckets = [for (var i = 0; i < 30; i++) _minute(i)];

        final controller = EnergyMonitorController(
          telemetryApi: api,
          now: () => _base.add(const Duration(minutes: 30)),
        );
        await controller.refresh();

        final series = controller.seriesForChartWidth(
          _chartWidth,
          capacity: AppSizes.chartBarProfile.slotsIn(
            _chartWidth - AppSizes.chartAxisGutter,
          ),
        );
        expect(series.width, const Duration(minutes: 2));
        expect(series.buckets, hasLength(30));
        expect(
          series.buckets.take(15).every((bucket) => !bucket.isEmpty),
          isTrue,
        );
        expect(
          series.buckets.skip(15).every((bucket) => bucket.isEmpty),
          isTrue,
        );
        controller.dispose();
      },
    );

    test(
      'a live chart keeps its scale while the final slot is filling',
      () async {
        final api = _FakeTelemetryApi()
          ..liveSessionId = 'trip-1'
          ..tripBuckets = [
            for (var i = 0; i < 29; i++) _minute(i),
            _minute(29, seconds: 30),
          ];

        final controller = EnergyMonitorController(
          telemetryApi: api,
          now: () => _base.add(const Duration(minutes: 29, seconds: 30)),
        );
        await controller.refresh();

        final series = controller.seriesForChartWidth(
          _chartWidth,
          capacity: AppSizes.chartBarProfile.slotsIn(
            _chartWidth - AppSizes.chartAxisGutter,
          ),
        );
        expect(series.width, EnergyBucket.oneMinute);
        expect(series.buckets, hasLength(30));
        expect(series.openIndex, 29);
        controller.dispose();
      },
    );

    test('the bar count never exceeds what the plot fits', () async {
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [for (var i = 0; i < 200; i++) _minute(i)];

      final controller = EnergyMonitorController(
        telemetryApi: api,
        now: () => _base.add(const Duration(minutes: 9, seconds: 30)),
      );
      await controller.refresh();

      final series = controller.seriesForChartWidth(
        _chartWidth,
        capacity: AppSizes.chartBarProfile.slotsIn(
          _chartWidth - AppSizes.chartAxisGutter,
        ),
      );
      expect(series.buckets.length, lessThanOrEqualTo(30));
      // Two hundred minutes has outgrown the one-minute bar.
      expect(series.width, greaterThan(EnergyBucket.oneMinute));
      controller.dispose();
    });

    test('a narrow plot takes a coarser bar rather than overflowing', () async {
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [for (var i = 0; i < 40; i++) _minute(i)];

      final controller = EnergyMonitorController(
        telemetryApi: api,
        now: () => _base.add(const Duration(minutes: 39, seconds: 30)),
      );
      await controller.refresh();

      final wide = controller.seriesForChartWidth(
        _chartWidth,
        capacity: AppSizes.chartBarProfile.slotsIn(
          _chartWidth - AppSizes.chartAxisGutter,
        ),
      );
      final narrow = controller.seriesForChartWidth(
        _chartWidth / 3,
        capacity: AppSizes.chartBarProfile.slotsIn(
          (_chartWidth / 3) - AppSizes.chartAxisGutter,
        ),
      );

      expect(narrow.width, greaterThan(wide.width));
      expect(
        narrow.buckets.where((bucket) => !bucket.isEmpty).length,
        lessThan(wide.buckets.where((bucket) => !bucket.isEmpty).length),
      );
      controller.dispose();
    });

    test('the minute still filling is marked open', () async {
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [_minute(0), _minute(1)]
        ..live = [_minute(2, seconds: 25, traction: 25)];

      final controller = EnergyMonitorController(
        telemetryApi: api,
        now: () => _base.add(const Duration(minutes: 2, seconds: 25)),
      );
      await controller.refresh();

      final series = controller.seriesForChartWidth(
        _chartWidth,
        capacity: AppSizes.chartBarProfile.slotsIn(
          _chartWidth - AppSizes.chartAxisGutter,
        ),
      );
      expect(series.openIndex, 2);
      controller.dispose();
    });

    test('a trip that ended has no minute in progress', () async {
      // The drive stopped 25 seconds into its last minute. Marking that bucket
      // open left an ended trip drawing a bar that claimed to be still filling
      // — for as long as the screen stayed on it.
      final api = _FakeTelemetryApi()
        ..liveSessionId = null
        ..windowBuckets = [
          _minute(0),
          _minute(1),
          _minute(2, seconds: 25, traction: 25),
        ]
        ..windowStart = _base;

      final controller = EnergyMonitorController(
        telemetryApi: api,
        now: () => _base.add(const Duration(minutes: 2, seconds: 40)),
      );
      controller.selectWindow(EnergyWindow.last15Minutes);
      await controller.refresh();

      expect(
        controller
            .seriesForChartWidth(
              _chartWidth,
              capacity: AppSizes.chartBarProfile.slotsIn(
                _chartWidth - AppSizes.chartAxisGutter,
              ),
            )
            .openIndex,
        isNull,
      );
      controller.dispose();
    });

    test('a trip running behind a data gap has no minute in progress', () async {
      // A session is open but nothing has landed for minutes. The newest bucket
      // is partial because the data stopped, not because it is filling.
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [_minute(0), _minute(1, seconds: 25, traction: 25)];

      final controller = EnergyMonitorController(
        telemetryApi: api,
        now: () => _base.add(const Duration(minutes: 9)),
      );
      await controller.refresh();

      expect(
        controller
            .seriesForChartWidth(
              _chartWidth,
              capacity: AppSizes.chartBarProfile.slotsIn(
                _chartWidth - AppSizes.chartAxisGutter,
              ),
            )
            .openIndex,
        isNull,
      );
      controller.dispose();
    });
    test(
      'an open minute past its recorded width is not still filling',
      () async {
        // The open-bucket check reads the clock against the RECORDED width. A
        // bucket whose end the clock has passed is final at whatever seconds it
        // measured — it must not read as a bar still filling.
        final api = _FakeTelemetryApi()
          ..liveSessionId = 'trip-1'
          ..tripBuckets = [_minute(0, traction: 180), _minute(1, seconds: 25)];

        final controller = EnergyMonitorController(
          telemetryApi: api,
          now: () => _base.add(const Duration(minutes: 2, seconds: 30)),
        );
        await controller.refresh();

        final series = controller.seriesForChartWidth(
          _chartWidth,
          capacity: AppSizes.chartBarProfile.slotsIn(
            _chartWidth - AppSizes.chartAxisGutter,
          ),
        );
        expect(series.openIndex, isNull);
        controller.dispose();
      },
    );

    test('a clock window drops a first bar that starts before it', () async {
      // "The last N minutes" lands wherever it lands, so the leading reduced
      // bar can cover a fraction of its interval and read as a drop.
      final api = _FakeTelemetryApi()
        ..liveSessionId = null
        // Enough minutes to force a five-minute bar at this width.
        ..windowBuckets = [for (var i = 3; i < 100; i++) _minute(i)]
        ..windowStart = _base.add(const Duration(minutes: 3));

      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.last8Hours);
      await controller.refresh();

      final series = controller.seriesForChartWidth(
        _chartWidth,
        capacity: AppSizes.chartBarProfile.slotsIn(
          _chartWidth - AppSizes.chartAxisGutter,
        ),
      );
      expect(series.width.inMinutes, greaterThan(1));
      // The 13:00 bar would have held only 13:03 and 13:04.
      expect(series.buckets.first.start.isBefore(api.windowStart), isFalse);
      controller.dispose();
    });

    test("a trip's own short first bar is kept", () async {
      // The drive starts at 13:03. Progressive widths are not forced onto
      // round clock divisors, so its first measured interval must stay present
      // instead of being trimmed like a clock window's arbitrary edge.
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [for (var i = 3; i < 100; i++) _minute(i)];

      final controller = EnergyMonitorController(telemetryApi: api);
      await controller.refresh();

      final series = controller.seriesForChartWidth(
        _chartWidth,
        capacity: AppSizes.chartBarProfile.slotsIn(
          _chartWidth - AppSizes.chartAxisGutter,
        ),
      );
      expect(series.buckets.first.start.minute, 3);
      expect(series.buckets.first.isEmpty, isFalse);
      controller.dispose();
    });

    test('gaps keep their place so the axis holds its scale', () async {
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [_minute(0), _minute(1), _minute(8), _minute(9)];

      final controller = EnergyMonitorController(
        telemetryApi: api,
        now: () => _base.add(const Duration(minutes: 9, seconds: 30)),
      );
      await controller.refresh();

      final series = controller.seriesForChartWidth(
        _chartWidth,
        capacity: AppSizes.chartBarProfile.slotsIn(
          _chartWidth - AppSizes.chartAxisGutter,
        ),
      );
      expect(series.buckets, hasLength(30));
      expect(series.buckets.where((b) => b.isEmpty), hasLength(26));
      controller.dispose();
    });

    test('an empty series resolves to an empty chart, not a crash', () async {
      final api = _FakeTelemetryApi()..liveSessionId = null;
      final controller = EnergyMonitorController(telemetryApi: api);
      await controller.refresh();

      expect(
        controller
            .seriesForChartWidth(
              _chartWidth,
              capacity: AppSizes.chartBarProfile.slotsIn(
                _chartWidth - AppSizes.chartAxisGutter,
              ),
            )
            .isEmpty,
        isTrue,
      );
      expect(controller.seriesForChartWidth(0, capacity: 0).isEmpty, isTrue);
      controller.dispose();
    });
  });

  group('the parked track', () {
    test(
      'a window with no parked minute offers no track to switch to',
      () async {
        final api = _FakeTelemetryApi()
          ..windowBuckets = [_minute(0), _minute(1)]
          ..parkedBuckets = const [];
        final controller = EnergyMonitorController(telemetryApi: api);
        controller.selectWindow(EnergyWindow.lastHour);
        await controller.refresh();

        expect(controller.hasParkedData, isFalse);
        controller.dispose();
      },
    );

    test(
      'the parked series is read even while the drive track is shown',
      () async {
        // The control can only decide whether to appear by knowing the answer,
        // so the read cannot wait for the reader to press it.
        final api = _FakeTelemetryApi()..parkedBuckets = [_parkedMinute(0)];
        final controller = EnergyMonitorController(telemetryApi: api);
        controller.selectWindow(EnergyWindow.lastHour);
        await controller.refresh();

        expect(controller.track, EnergyTrack.drive);
        expect(api.parkedReads, greaterThan(0));
        expect(controller.hasParkedData, isTrue);
        controller.dispose();
      },
    );

    test('selecting parked swaps the series without a new read', () async {
      final api = _FakeTelemetryApi()
        ..windowBuckets = [_minute(0), _minute(1)]
        ..parkedBuckets = [_parkedMinute(10), _parkedMinute(11)];
      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.lastHour);
      await controller.refresh();

      final readsBefore = api.parkedReads;
      controller.selectTrack(EnergyTrack.parked);

      expect(
        controller.minutes.every((bucket) => bucket.tractionWh == 0),
        isTrue,
      );
      expect(api.parkedReads, readsBefore);
      controller.dispose();
    });

    test(
      'the current drive has no parked reading and refuses the track',
      () async {
        final api = _FakeTelemetryApi()
          ..liveSessionId = 'trip-1'
          ..tripBuckets = [_minute(0)]
          ..parkedBuckets = [_parkedMinute(0)];
        final controller = EnergyMonitorController(telemetryApi: api);
        await controller.refresh();

        controller.selectTrack(EnergyTrack.parked);

        expect(controller.window, EnergyWindow.currentDrive);
        expect(controller.track, EnergyTrack.drive);
        expect(controller.hasParkedData, isFalse);
        controller.dispose();
      },
    );

    test(
      'leaving a clock window for the drive returns to the drive track',
      () async {
        final api = _FakeTelemetryApi()
          ..liveSessionId = 'trip-1'
          ..tripBuckets = [_minute(0)]
          ..parkedBuckets = [_parkedMinute(0)];
        final controller = EnergyMonitorController(telemetryApi: api);
        controller.selectWindow(EnergyWindow.lastHour);
        await controller.refresh();
        controller.selectTrack(EnergyTrack.parked);
        expect(controller.track, EnergyTrack.parked);

        controller.selectWindow(EnergyWindow.currentDrive);

        expect(controller.track, EnergyTrack.drive);
        controller.dispose();
      },
    );

    test('drive stats do not describe a parked window', () async {
      final api = _FakeTelemetryApi()
        ..windowBuckets = [_minute(0)]
        ..parkedBuckets = [_parkedMinute(0, auxiliary: 2)];
      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.lastHour);
      await controller.refresh();
      controller.selectTrack(EnergyTrack.parked);

      // Not a null efficiency inside a stats object — no drive stats at all.
      expect(controller.selectedStats, isNull);
      expect(controller.parkedStats, isNotNull);
      controller.dispose();
    });

    test('the parked rate is the average over the seconds measured', () async {
      // 2 Wh in a minute is 120 W, and 1 Wh over the half minute the daemon
      // covered is the same rate rather than half of it.
      final api = _FakeTelemetryApi()
        ..parkedBuckets = [
          _parkedMinute(0, auxiliary: 2),
          _parkedMinute(1, auxiliary: 1, seconds: 30, climateSeconds: 30),
        ];
      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.lastHour);
      await controller.refresh();
      controller.selectTrack(EnergyTrack.parked);

      final stats = controller.parkedStats!;
      expect(stats.averageDrainW, closeTo(120, 0.01));
      expect(stats.totalEnergyKwh, closeTo(0.003, 1e-9));
      expect(stats.measuredSeconds, 90);
      controller.dispose();
    });

    test('a partly covered climate reading is not a climate figure', () async {
      // The split is refused rather than charging the uncovered seconds to the
      // system share, so the named figure is absent instead of understated.
      final api = _FakeTelemetryApi()
        ..parkedBuckets = [
          _parkedMinute(0, auxiliary: 14, climate: 11, climateSeconds: 21),
        ];
      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.lastHour);
      await controller.refresh();
      controller.selectTrack(EnergyTrack.parked);

      expect(controller.parkedStats!.climateShareKwh, isNull);
      controller.dispose();
    });

    test('a covered climate reading of zero is a measurement', () async {
      final api = _FakeTelemetryApi()
        ..parkedBuckets = [_parkedMinute(0, auxiliary: 2, climate: 0)];
      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.lastHour);
      await controller.refresh();
      controller.selectTrack(EnergyTrack.parked);

      expect(controller.parkedStats!.climateShareKwh, 0);
      controller.dispose();
    });

    test('the parked chart has no bucket still filling', () async {
      // Nothing publishes an open parked minute, so a bar that is short is a
      // minute that drew little rather than one that is still being written.
      final api = _FakeTelemetryApi()
        ..parkedBuckets = [_parkedMinute(0), _parkedMinute(1)];
      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.lastHour);
      await controller.refresh();
      controller.selectTrack(EnergyTrack.parked);

      expect(
        controller
            .seriesForChartWidth(
              _chartWidth,
              capacity: AppSizes.chartBarProfile.slotsIn(
                _chartWidth - AppSizes.chartAxisGutter,
              ),
            )
            .openIndex,
        isNull,
      );
      controller.dispose();
    });

    test('a parked write refreshes the parked series', () async {
      final api = _FakeTelemetryApi()..parkedBuckets = [_parkedMinute(0)];
      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.lastHour);
      controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final before = api.parkedReads;

      api.sessions.add(
        const SessionChange(
          revision: 1,
          trips: false,
          charges: false,
          parked: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(api.parkedReads, greaterThan(before));
      controller.stop();
      controller.dispose();
    });
  });

  group('sincePowerOn window (issue 199/207)', () {
    test('absent from the selector while the mode is off', () async {
      final api = _FakeTelemetryApi()..continuousModeEnabled = false;
      final controller = EnergyMonitorController(telemetryApi: api);
      await controller.refresh();

      expect(controller.continuousModeEnabled, isFalse);
      expect(
        controller.availableWindows,
        isNot(contains(EnergyWindow.sincePowerOn)),
      );
      controller.dispose();
    });

    test('offered once the mode is on', () async {
      final api = _FakeTelemetryApi()..continuousModeEnabled = true;
      final controller = EnergyMonitorController(telemetryApi: api);
      await controller.refresh();

      expect(controller.continuousModeEnabled, isTrue);
      expect(controller.availableWindows, contains(EnergyWindow.sincePowerOn));
      // Every other window is still offered: this is an addition, not a
      // replacement.
      expect(
        controller.availableWindows,
        containsAll([
          EnergyWindow.currentDrive,
          EnergyWindow.last15Minutes,
          EnergyWindow.lastHour,
          EnergyWindow.last8Hours,
        ]),
      );
      controller.dispose();
    });

    test(
      'plots the stored continuous minutes plus the live tail as one series',
      () async {
        final api = _FakeTelemetryApi()
          ..continuousModeEnabled = true
          ..liveContinuousSessionId = 'continuous-1'
          ..continuousBuckets = [
            _minute(0, traction: 5, auxiliary: 40),
            _minute(1, seconds: 20, traction: 2, auxiliary: 13),
          ]
          ..liveContinuous = [
            _minute(1, seconds: 55, traction: 6, auxiliary: 36),
          ];
        final controller = EnergyMonitorController(telemetryApi: api);
        await controller.refresh();
        controller.selectWindow(EnergyWindow.sincePowerOn);
        await controller.refresh();

        expect(controller.window, EnergyWindow.sincePowerOn);
        // The database only saw the tail of minute 1; memory saw more of it,
        // so the merge takes memory's wider coverage — mergeEnergyBuckets'
        // own rule, exercised here through the controller.
        expect(controller.minutes, hasLength(2));
        expect(controller.minutes.last.auxiliaryWh, 36);
        controller.dispose();
      },
    );

    test('the figures keep updating with no trip running', () async {
      final api = _FakeTelemetryApi()
        ..continuousModeEnabled = true
        ..liveSessionId =
            null // no trip
        ..liveContinuousSessionId = 'continuous-1'
        ..continuousBuckets = [_minute(0, traction: 30, auxiliary: 10)];
      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.sincePowerOn);
      await controller.refresh();

      expect(controller.activeSessionId, isNull);
      expect(controller.activeContinuousSessionId, 'continuous-1');
      // The gauges answer from the continuous minutes, not from a trip that
      // does not exist.
      expect(controller.minutes, hasLength(1));
      expect(controller.minutes.single.tractionWh, 30);
      controller.dispose();
    });

    /// One measured kilometre, so [EnergyMonitorStats.measuredKmPerKwh]
    /// answers a number rather than null — [_minute] carries no distance.
    ///
    /// Set on [EnergyBucket.speedDistanceKm], because [_interval] carries a
    /// stored row's one `distance` field from that source, the same as the
    /// real store's `IntervalRecord.distance`.
    EnergyBucket driveShapedMinute(double tractionWh) => EnergyBucket(
      start: _base,
      width: EnergyBucket.oneMinute,
      tractionWh: tractionWh,
      regeneratedWh: 0,
      auxiliaryWh: 0,
      integratedSeconds: 60,
      speedDistanceKm: 1.0,
    );

    test(
      'choosing the window recalculates the gauges over that period',
      () async {
        final api = _FakeTelemetryApi()
          ..continuousModeEnabled = true
          ..liveContinuousSessionId = 'continuous-1'
          ..continuousBuckets = [driveShapedMinute(100)]
          ..liveSessionId = 'trip-1'
          ..tripBuckets = [driveShapedMinute(10)];
        final controller = EnergyMonitorController(telemetryApi: api);
        await controller.refresh();

        final driveEfficiency = controller.selectedStats?.measuredKmPerKwh;
        expect(driveEfficiency, isNotNull);

        controller.selectWindow(EnergyWindow.sincePowerOn);
        await controller.refresh();
        final sincePowerOnEfficiency =
            controller.selectedStats?.measuredKmPerKwh;

        // Same distance, ten times the energy: the gauge is scored over the
        // newly selected period, not left showing the drive's number.
        expect(sincePowerOnEfficiency, isNotNull);
        expect(sincePowerOnEfficiency, isNot(driveEfficiency));
        controller.dispose();
      },
    );

    test('currentDrive still gives the per-trip reading, unchanged', () async {
      final api = _FakeTelemetryApi()
        ..continuousModeEnabled = true
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [_minute(0, traction: 8)]
        ..liveContinuousSessionId = 'continuous-1'
        ..continuousBuckets = [_minute(0, traction: 500)];
      final controller = EnergyMonitorController(telemetryApi: api);
      await controller.refresh();

      expect(controller.window, EnergyWindow.currentDrive);
      expect(controller.minutes, hasLength(1));
      expect(controller.minutes.single.tractionWh, 8);
      controller.dispose();
    });

    test('turning the mode off falls back to currentDrive and keeps the '
        'recorded minutes reachable through it', () async {
      final api = _FakeTelemetryApi()
        ..continuousModeEnabled = true
        ..liveContinuousSessionId = 'continuous-1'
        ..continuousBuckets = [_minute(0)]
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [_minute(5)];
      final controller = EnergyMonitorController(
        telemetryApi: api,
        storedReloadInterval: const Duration(milliseconds: 20),
      );
      controller.selectWindow(EnergyWindow.sincePowerOn);
      controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      api.continuousModeEnabled = false;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(controller.window, EnergyWindow.currentDrive);
      expect(
        controller.availableWindows,
        isNot(contains(EnergyWindow.sincePowerOn)),
      );
      // The trip's own minutes are what currentDrive shows now — recorded
      // continuous data was never deleted, just no longer selected.
      expect(controller.minutes.single.start, _minute(5).start);
      controller.stop();
      controller.dispose();
    });

    test(
      'a stretch the mode missed is a gap, never a fabricated zero minute',
      () async {
        final api = _FakeTelemetryApi()
          ..continuousModeEnabled = true
          ..liveContinuousSessionId = 'continuous-1'
          // Minute 5 is absent, the way a stretch recorded with the mode off
          // is absent from what the car stored.
          ..continuousBuckets = [_minute(0), _minute(6)];
        final controller = EnergyMonitorController(telemetryApi: api);
        controller.selectWindow(EnergyWindow.sincePowerOn);
        await controller.refresh();

        expect(controller.minutes, hasLength(2));
        expect(controller.minutes.map((b) => b.start), [
          _minute(0).start,
          _minute(6).start,
        ]);
        controller.dispose();
      },
    );

    test(
      'the chart series labels each minute against the fetched session spans',
      () async {
        final api = _FakeTelemetryApi()
          ..continuousModeEnabled = true
          ..liveContinuousSessionId = 'continuous-1'
          ..continuousBuckets = [_minute(0), _minute(1), _minute(2)]
          // A charge covering minute 1 only. Minutes 0 and 2 are covered by
          // no session at all.
          ..sessionSpans = [
            SessionSpan(
              kind: SessionKind.charge,
              start: _minute(1).start,
              end: _minute(1).end,
            ),
          ];
        final controller = EnergyMonitorController(
          telemetryApi: api,
          now: () => _minute(2).end,
        );
        controller.selectWindow(EnergyWindow.sincePowerOn);
        await controller.refresh();

        final series = controller.seriesForChartWidth(
          _chartWidth,
          capacity: AppSizes.chartBarProfile.slotsIn(
            _chartWidth - AppSizes.chartAxisGutter,
          ),
        );

        expect(series.labels, isNotNull);
        expect(series.labels, hasLength(series.buckets.length));
        final byBucketStart = {
          for (var i = 0; i < series.buckets.length; i++)
            series.buckets[i].start: series.labels![i],
        };
        expect(byBucketStart[_minute(0).start], ContinuousLabel.poweredOn);
        expect(byBucketStart[_minute(1).start], ContinuousLabel.charge);
        expect(byBucketStart[_minute(2).start], ContinuousLabel.poweredOn);
        controller.dispose();
      },
    );

    test('outside sincePowerOn the chart series carries no labels', () async {
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [_minute(0)];
      final controller = EnergyMonitorController(telemetryApi: api);
      await controller.refresh();

      final series = controller.seriesForChartWidth(
        _chartWidth,
        capacity: AppSizes.chartBarProfile.slotsIn(
          _chartWidth - AppSizes.chartAxisGutter,
        ),
      );

      expect(series.labels, isNull);
      controller.dispose();
    });
  });

  group('sleep-gap estimate (issue 199/211)', () {
    test(
      'a gap inside a PARKED span carrying an estimate is filled and marked',
      () async {
        final api = _FakeTelemetryApi()
          ..continuousModeEnabled = true
          ..liveContinuousSessionId = 'continuous-1'
          // Minutes 2, 3 and 4 are genuinely absent -- the car was asleep.
          ..continuousBuckets = [_minute(0), _minute(1), _minute(5)]
          ..sessionSpans = [
            SessionSpan(
              kind: SessionKind.parked,
              start: _minute(0).start,
              end: _minute(5).start,
              sleepSeconds: 180,
              sleepSocDeltaPercent: 1.2,
              sleepEnergyWhEstimate: 90,
            ),
          ];
        final controller = EnergyMonitorController(
          telemetryApi: api,
          now: () => _minute(5).end,
        );
        controller.selectWindow(EnergyWindow.sincePowerOn);
        await controller.refresh();

        expect(controller.minutes, hasLength(6));
        final byStart = {
          for (final bucket in controller.minutes) bucket.start: bucket,
        };
        for (final gap in [
          _minute(2).start,
          _minute(3).start,
          _minute(4).start,
        ]) {
          expect(byStart[gap]!.auxiliaryWh, closeTo(30, 1e-9));
          expect(byStart[gap]!.isEmpty, isFalse);
        }

        final series = controller.seriesForChartWidth(
          _chartWidth,
          capacity: AppSizes.chartBarProfile.slotsIn(
            _chartWidth - AppSizes.chartAxisGutter,
          ),
        );
        expect(series.estimated, isNotNull);
        final estimatedByStart = {
          for (var i = 0; i < series.buckets.length; i++)
            series.buckets[i].start: series.estimated![i],
        };
        expect(estimatedByStart[_minute(0).start], isFalse);
        expect(estimatedByStart[_minute(1).start], isFalse);
        expect(estimatedByStart[_minute(2).start], isTrue);
        expect(estimatedByStart[_minute(3).start], isTrue);
        expect(estimatedByStart[_minute(4).start], isTrue);
        expect(estimatedByStart[_minute(5).start], isFalse);
        controller.dispose();
      },
    );

    test('a gap inside a PARKED span with no estimate stays a gap, not '
        'a fabricated minute', () async {
      final api = _FakeTelemetryApi()
        ..continuousModeEnabled = true
        ..liveContinuousSessionId = 'continuous-1'
        ..continuousBuckets = [_minute(0), _minute(5)]
        ..sessionSpans = [
          SessionSpan(
            kind: SessionKind.parked,
            start: _minute(0).start,
            end: _minute(5).start,
          ),
        ];
      final controller = EnergyMonitorController(
        telemetryApi: api,
        now: () => _minute(5).end,
      );
      controller.selectWindow(EnergyWindow.sincePowerOn);
      await controller.refresh();

      expect(controller.minutes, hasLength(2));
      expect(controller.minutes.map((b) => b.start), [
        _minute(0).start,
        _minute(5).start,
      ]);
      controller.dispose();
    });

    test('the ledger names a total that folds in the sleep estimate', () async {
      final api = _FakeTelemetryApi()
        ..continuousModeEnabled = true
        ..liveContinuousSessionId = 'continuous-1'
        ..continuousBuckets = [_minute(0), _minute(2)]
        ..sessionSpans = [
          SessionSpan(
            kind: SessionKind.parked,
            start: _minute(0).start,
            end: _minute(2).start,
            sleepSeconds: 60,
            sleepSocDeltaPercent: 0.5,
            sleepEnergyWhEstimate: 24,
          ),
        ];
      final controller = EnergyMonitorController(
        telemetryApi: api,
        now: () => _minute(2).end,
      );
      controller.selectWindow(EnergyWindow.sincePowerOn);
      await controller.refresh();

      final stats = controller.ledgerStats;
      expect(stats, isNotNull);
      expect(stats!.includesEstimate, isTrue);
      controller.dispose();
    });

    test(
      'a ledger with no estimated minute does not claim to include one',
      () async {
        final api = _FakeTelemetryApi()
          ..continuousModeEnabled = true
          ..liveContinuousSessionId = 'continuous-1'
          ..continuousBuckets = [_minute(0), _minute(1)];
        final controller = EnergyMonitorController(telemetryApi: api);
        controller.selectWindow(EnergyWindow.sincePowerOn);
        await controller.refresh();

        expect(controller.ledgerStats!.includesEstimate, isFalse);
        controller.dispose();
      },
    );
  });

  group('ledgerStats (issue 199/210)', () {
    EnergyBucket driveMinute() => EnergyBucket(
      start: _base,
      width: EnergyBucket.oneMinute,
      tractionWh: 300,
      regeneratedWh: 20,
      auxiliaryWh: 40,
      integratedSeconds: 60,
      startSoc: 82,
      endSoc: 81,
    );

    EnergyBucket chargeMinute() => EnergyBucket(
      start: _base.add(const Duration(minutes: 1)),
      width: EnergyBucket.oneMinute,
      tractionWh: 0,
      regeneratedWh: 0,
      auxiliaryWh: 5,
      deliveredWh: 1800,
      integratedSeconds: 60,
    );

    EnergyBucket parkedMinute() => EnergyBucket(
      start: _base.add(const Duration(minutes: 2)),
      width: EnergyBucket.oneMinute,
      tractionWh: 0,
      regeneratedWh: 0,
      auxiliaryWh: 8,
      integratedSeconds: 60,
      endSoc: 84,
    );

    test('null outside sincePowerOn', () async {
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [driveMinute()];
      final controller = EnergyMonitorController(telemetryApi: api);
      await controller.refresh();

      expect(controller.ledgerStats, isNull);
      controller.dispose();
    });

    test('sums in, out and the balance over a window holding a drive, a '
        'charge and standing time', () async {
      final api = _FakeTelemetryApi()
        ..continuousModeEnabled = true
        ..liveContinuousSessionId = 'continuous-1'
        ..continuousBuckets = [driveMinute(), chargeMinute(), parkedMinute()];
      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.sincePowerOn);
      await controller.refresh();

      final stats = controller.ledgerStats;
      expect(stats, isNotNull);
      // In: regen (20) from the drive, delivered (1800) from the charge.
      expect(stats!.inWh, 20 + 1800);
      // Out: traction (300) + auxiliary (40, 5, 8) across all three.
      expect(stats.outWh, 300 + 40 + 5 + 8);
      expect(stats.balanceWh, stats.inWh - stats.outWh);
      // Cross-check: the first bucket's start SOC, the last bucket's end
      // SOC that actually carried one -- the charge minute in the middle
      // carries neither, and must not blank the reading.
      expect(stats.startSoc, 82);
      expect(stats.endSoc, 84);
      controller.dispose();
    });

    test('shows figures instead of dashes with no trip running', () async {
      final api = _FakeTelemetryApi()
        ..continuousModeEnabled = true
        ..liveSessionId = null
        ..liveContinuousSessionId = 'continuous-1'
        ..continuousBuckets = [parkedMinute()];
      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.sincePowerOn);
      await controller.refresh();

      expect(controller.activeSessionId, isNull);
      expect(controller.ledgerStats, isNotNull);
      controller.dispose();
    });

    test('changing the window changes the ledger to that period', () async {
      final api = _FakeTelemetryApi()
        ..continuousModeEnabled = true
        ..liveContinuousSessionId = 'continuous-1'
        ..continuousBuckets = [driveMinute()]
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [chargeMinute()];
      final controller = EnergyMonitorController(telemetryApi: api);
      controller.selectWindow(EnergyWindow.sincePowerOn);
      await controller.refresh();
      final sincePowerOnOut = controller.ledgerStats!.outWh;

      controller.selectWindow(EnergyWindow.currentDrive);
      await controller.refresh();

      expect(controller.ledgerStats, isNull);
      expect(sincePowerOnOut, 300 + 40);
      controller.dispose();
    });
  });

  test(
    'one future-default stamp does not widen the live axis to 22000 hours',
    () async {
      // A nine-minute live drive whose last minute carries a boot-default
      // stamp years *ahead* of the session. The stamp difference would make
      // the axis span ~22352 hours; the recorded rows are all the minute.
      final futureStart = DateTime(2027, 12, 29, 9);
      final api = _FakeTelemetryApi()
        ..liveSessionId = 'trip-1'
        ..tripBuckets = [
          for (var i = 0; i < 8; i++) _minute(i),
          EnergyBucket(
            start: futureStart,
            width: EnergyBucket.oneMinute,
            tractionWh: 60,
            regeneratedWh: 0,
            auxiliaryWh: 6,
            integratedSeconds: 60,
          ),
        ];
      final controller = EnergyMonitorController(
        telemetryApi: api,
        now: () => _base.add(const Duration(minutes: 9)),
      );
      await controller.refresh();

      final series = controller.seriesForChartWidth(
        _chartWidth,
        capacity: AppSizes.chartBarProfile.slotsIn(
          _chartWidth - AppSizes.chartAxisGutter,
        ),
      );
      // Nine measured minutes: the axis is the recorded width, never the
      // wall-clock difference between a bogus stamp and the session.
      expect(series.buckets.where((bucket) => !bucket.isEmpty).length, 9);
      expect(energyBucketSpan(controller.minutes), const Duration(minutes: 9));
      controller.dispose();
    },
  );
}
