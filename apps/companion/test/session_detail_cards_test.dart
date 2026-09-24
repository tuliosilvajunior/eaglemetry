import 'package:capy_companion/l10n/app_localizations.dart';
import 'package:capy_companion/screens/charge_detail_screen.dart';
import 'package:capy_companion/screens/trip_detail_screen.dart';
import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/sqflite_store.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'support/memory_archive.dart';

/// What the drive detail shows, and what it refuses to show.
///
/// The rule under test is one decision: a card whose measurement the car never
/// took is absent, not drawn empty. An empty energy balance would state that
/// the drive spent nothing, which is a claim about the car; an absent card
/// states that this phone cannot answer, which is the truth.
void main() {
  const startMillis = 1750000000000;

  Widget host(Widget child) => MaterialApp(
    locale: const Locale('en'),
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );

  Future<T> real<T>(WidgetTester tester, Future<T> Function() body) async =>
      (await tester.runAsync(body)) as T;

  /// Lets the screen's own reads answer, then rebuilds with what they
  /// answered. Not a `pumpAndSettle`: the spinner schedules a frame forever, so
  /// a settle would run to its timeout instead of to a ready screen.
  Future<void> readsLand(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  /// The row the list handed over. The screen re-reads it from the store, so
  /// this only has to name the session.
  final trip = SessionRecord(
    id: 'trip-1',
    vehicleId: 'test',
    kind: SessionKind.trip,
    status: 'CLOSED',
    startedAtUtcMillis: startMillis,
    startedAtElapsedNanos: 1000000000,
    endedAtUtcMillis: startMillis + 120000,
    endedAtElapsedNanos: 121000000000,
    rollup: const SessionRollup(
      distance: Measurement.unreported(unit: 'km'),
      traction: Measurement.unreported(unit: 'Wh'),
      regen: Measurement.unreported(unit: 'Wh'),
      auxiliary: Measurement.unreported(unit: 'Wh'),
      climate: Measurement.unreported(unit: 'Wh'),
      delivered: Measurement.unreported(unit: 'Wh'),
      integratedSeconds: Measurement.unreported(unit: 's'),
    ),
    startOdometer: const Measurement.measured(1000, unit: 'km'),
    endOdometer: const Measurement.measured(1010, unit: 'km'),
    startSoc: const Measurement.measured(80, unit: '%'),
    endSoc: const Measurement.measured(62, unit: '%'),
    minSoc: const Measurement.measured(62, unit: '%'),
    maxSoc: const Measurement.measured(80, unit: '%'),
    startAmbientTemp: const Measurement.measured(21, unit: '°C'),
    endAmbientTemp: const Measurement.measured(21, unit: '°C'),
    meanAmbientTemp: const Measurement.measured(21, unit: '°C'),
    createdAtUtcMillis: startMillis,
    updatedAtUtcMillis: startMillis,
  );

  /// Two minutes of samples, with the minutes the car folded or without them.
  Future<CompanionArchive> archiveWith(
    WidgetTester tester, {
    required bool withCan,
  }) async {
    final archive = await real(tester, memoryArchive);
    await real(tester, () async {
      await archive.upsertTrip({
        'id': 'trip-1',
        'status': 'CLOSED',
        'startedAtUtcMillis': startMillis,
        'endedAtUtcMillis': startMillis + 120000,
        // The car sends endpoints, never a duration. Two minutes of drive,
        // stamped on one boot.
        'startedAtElapsedNanos': 1000000000,
        'startedAtBootCount': 3,
        'endedAtElapsedNanos': 121000000000,
        'endedAtBootCount': 3,
        'startSocPercent': 80,
        'endSocPercent': 62,
        'startOdometerKm': 1000,
        'endOdometerKm': 1010,
        if (withCan) ...{
          // The rollup is the sum of the two minutes below.
          'rollupTractionWh': 20.0 * 119 / 3600 * 1000,
          'rollupRegenWh': 0.0,
          'rollupAuxiliaryWh': 2.0 * 119 / 3600 * 1000,
          'rollupDistanceKm': 1.653,
          'rollupIntegratedSeconds': 119.0,
        },
      });
      if (withCan) {
        await archive.upsertInterval({
          'sessionId': 'trip-1',
          'startUtcMillis': startMillis,
          'tractionWh': 20.0 * 60 / 3600 * 1000,
          'regeneratedWh': 0.0,
          'auxiliaryWh': 2.0 * 60 / 3600 * 1000,
          'integratedSeconds': 60.0,
          'speedDistanceKm': 0.833,
          'odometerDistanceKm': 0.833,
          'speedIntegratedSeconds': 60.0,
          'climateWh': 0.0,
          'climateIntegratedSeconds': 0.0,
        });
        await archive.upsertInterval({
          'sessionId': 'trip-1',
          'startUtcMillis': startMillis + 60000,
          'tractionWh': 20.0 * 59 / 3600 * 1000,
          'regeneratedWh': 0.0,
          'auxiliaryWh': 2.0 * 59 / 3600 * 1000,
          'integratedSeconds': 59.0,
          'speedDistanceKm': 0.82,
          'odometerDistanceKm': 0.82,
          'speedIntegratedSeconds': 59.0,
          'climateWh': 0.0,
          'climateIntegratedSeconds': 0.0,
        });
      }
      final track = TrackCodec.encode(const [
        TrackPoint(
          latitude: -23.5,
          longitude: -46.6,
          tSeconds: 0,
          speedKmh: 30,
          altitudeM: 700,
        ),
        TrackPoint(
          latitude: -23.51,
          longitude: -46.61,
          tSeconds: 119,
          speedKmh: 30,
          altitudeM: 819,
        ),
      ]);
      await archive.upsertTrack({
        'sessionId': 'trip-1',
        'encodingVersion': track.encodingVersion,
        'pointCount': track.pointCount,
        'path': track.path,
        't': track.t,
        'speed': track.speed,
        'alt': track.alt,
      });
    });
    return archive;
  }

  Future<void> open(WidgetTester tester, CompanionArchive archive) async {
    await tester.pumpWidget(
      host(
        TripDetailScreen(store: SqfliteStore(archive.database), session: trip),
      ),
    );
    // The store answers on a real thread. Poll until the screen has a list or
    // fails, instead of betting on one delay length (a run under load answered
    // slower than the old fixed 200 ms wait).
    for (var attempt = 0; attempt < 40; attempt++) {
      await real(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      if (find.byType(Scrollable).evaluate().isNotEmpty) return;
    }
    fail('TripDetailScreen never landed a scrollable list');
  }

  /// Scrolls the detail list without gestures.
  ///
  /// A drag cannot be trusted here: the first card is the route map, which
  /// swallows a drag that starts above it, and the scrollable's centre sits
  /// squarely on the map. Jumping the position instead is deterministic.
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    for (var i = 0; i < 40 && target.evaluate().isEmpty; i++) {
      position.jumpTo(
        (position.pixels + 300).clamp(0.0, position.maxScrollExtent),
      );
      await tester.pump();
    }
    expect(target, findsWidgets);
  }

  testWidgets('a drive the car measured carries the energy cards', (
    tester,
  ) async {
    await open(tester, await archiveWith(tester, withCan: true));

    // The battery span needs no CAN at all: the session's own two ends carry
    // it, so it is present on every closed drive.
    await scrollTo(tester, find.byType(SocSpanBar));
    expect(find.byType(SocSpanBar), findsOneWidget);

    // Three magnitudes on one scale. Recovered energy is measured against the
    // energy drawn, not carved out of it, so it has no slice of a whole.
    await scrollTo(tester, find.byType(MagnitudeBars));
    expect(find.byType(MagnitudeBars), findsOneWidget);
    // 20 kW of drive and 22 kW from the pack, over 119 s.
    expect(find.text('661 Wh'), findsOneWidget);
    expect(find.text('66 Wh'), findsOneWidget);
    expect(find.text('0 Wh'), findsOneWidget);
    expect(find.textContaining('net consumed'), findsOneWidget);

    await scrollTo(tester, find.byType(EnergyBarChart));
    final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
    // Regeneration goes on `counter`, not on `base`. A base segment follows
    // the column's direction, so a part that disagrees with it is dropped and
    // the recovered energy vanishes without a word.
    expect(chart.bars.every((bar) => bar.counter <= 0), isTrue);
    // And the axis has to be stated on both sides of zero, or every counter
    // column is drawn past the plot floor and clipped away.
    expect(chart.ticks.any((tick) => tick.value < 0), isTrue);
    expect(chart.ticks.any((tick) => tick.value > 0), isTrue);

    // The chart is readable, not just drawable: a column opens and says what
    // that minute spent and what it gave back.
    expect(chart.onSelected, isNotNull);
    expect(chart.tooltipBuilder, isNotNull);
    expect(chart.xTicks, isNotEmpty);

    // Tapped at a point inside the plot, past the axis gutter on the left.
    // A tap on the widget's centre is not the same thing: the chart selects by
    // where in the domain the pointer landed.
    await tester.tapAt(
      tester.getTopLeft(find.byType(EnergyBarChart)) + const Offset(80, 40),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChartTooltip), findsOneWidget);
    // The tooltip names what the minute recovered, once. The card's own
    // "Recovered" label is not this claim; the tooltip row is.
    expect(
      find.descendant(
        of: find.byType(ChartTooltip),
        matching: find.textContaining('Recovered'),
      ),
      findsOneWidget,
    );
    // The chart already draws a caret at the column it opened. The bubble's
    // own default adds a second one under the panel, pointing at nothing.
    expect(
      tester.widget<ChartTooltip>(find.byType(ChartTooltip)).side,
      ChartTooltipSide.none,
    );
  });

  testWidgets(
    'a drive with climate consumption shows climate in energy balance',
    (tester) async {
      final archive = await real(tester, memoryArchive);
      await real(tester, () async {
        await archive.upsertTrip({
          'id': 'trip-climate',
          'status': 'CLOSED',
          'startedAtUtcMillis': startMillis,
          'endedAtUtcMillis': startMillis + 120000,
          'startedAtElapsedNanos': 1000000000,
          'startedAtBootCount': 3,
          'endedAtElapsedNanos': 121000000000,
          'endedAtBootCount': 3,
          'startSocPercent': 80,
          'endSocPercent': 70,
          'startOdometerKm': 1000,
          'endOdometerKm': 1005,
          'rollupTractionWh': 500.0,
          'rollupRegenWh': 50.0,
          'rollupAuxiliaryWh': 100.0,
          'rollupClimateWh': 60.0,
          'rollupDistanceKm': 5.0,
          'rollupIntegratedSeconds': 120.0,
        });
      });

      final tripRecord = SessionRecord(
        id: 'trip-climate',
        vehicleId: 'test',
        kind: SessionKind.trip,
        status: 'CLOSED',
        startedAtUtcMillis: startMillis,
        startedAtElapsedNanos: 1000000000,
        endedAtUtcMillis: startMillis + 120000,
        endedAtElapsedNanos: 121000000000,
        rollup: const SessionRollup(
          distance: Measurement.measured(5, unit: 'km'),
          traction: Measurement.measured(500, unit: 'Wh'),
          regen: Measurement.measured(50, unit: 'Wh'),
          auxiliary: Measurement.measured(100, unit: 'Wh'),
          climate: Measurement.measured(60, unit: 'Wh'),
          delivered: Measurement.unreported(unit: 'Wh'),
          integratedSeconds: Measurement.measured(120, unit: 's'),
        ),
        startOdometer: const Measurement.measured(1000, unit: 'km'),
        endOdometer: const Measurement.measured(1005, unit: 'km'),
        startSoc: const Measurement.measured(80, unit: '%'),
        endSoc: const Measurement.measured(70, unit: '%'),
        minSoc: const Measurement.measured(70, unit: '%'),
        maxSoc: const Measurement.measured(80, unit: '%'),
        startAmbientTemp: const Measurement.measured(21, unit: '°C'),
        endAmbientTemp: const Measurement.measured(21, unit: '°C'),
        meanAmbientTemp: const Measurement.measured(21, unit: '°C'),
        createdAtUtcMillis: startMillis,
        updatedAtUtcMillis: startMillis,
      );

      final store = SqfliteStore(archive.database);
      await tester.pumpWidget(
        host(TripDetailScreen(store: store, session: tripRecord)),
      );
      await readsLand(tester);

      await scrollTo(tester, find.byType(MagnitudeBars));
      expect(find.byType(MagnitudeBars), findsOneWidget);
      expect(find.text('500 Wh'), findsOneWidget); // Traction
      expect(find.text('50 Wh'), findsOneWidget); // Recovered
      expect(find.text('60 Wh'), findsOneWidget); // Climate
      expect(find.text('40 Wh'), findsOneWidget); // Other systems (100 - 60)
      expect(find.text('Climate'), findsOneWidget);
      expect(find.text('Other systems'), findsOneWidget);
    },
  );

  testWidgets(
    'a drive with no CAN power hides those cards, and draws no zero',
    (tester) async {
      await open(tester, await archiveWith(tester, withCan: false));

      // Present: the drive still happened, and the archive still holds its ends
      // and its terrain.
      await scrollTo(tester, find.byType(SocSpanBar));
      expect(find.byType(SocSpanBar), findsOneWidget);
      // Scrolled to by its title. The card holds two traces, and a `.first`
      // on a widget the list has not built yet throws instead of simply not
      // matching — which is what a scroll-until-visible is there to solve.
      await scrollTo(tester, find.text('Terrain and weather'));
      expect(find.byType(SeriesTrace), findsWidgets);

      // Absent: nothing measured the split, so nothing states one.
      expect(find.byType(MagnitudeBars), findsNothing);
      expect(find.byType(EnergyBarChart), findsNothing);
      expect(find.text('Energy balance'), findsNothing);
    },
  );
  testWidgets('a long drive keeps every column on the screen', (tester) async {
    // A hundred minutes, sampled every five seconds. At one column per minute
    // this series is five times wider than a phone, so the chart either widens
    // the column or answers for the start of the drive and drops the rest.
    const minutes = 100;
    final archive = await real(tester, memoryArchive);
    await real(tester, () async {
      await archive.upsertTrip({
        'id': 'trip-1',
        'status': 'CLOSED',
        'startedAtUtcMillis': startMillis,
        'endedAtUtcMillis': startMillis + minutes * 60000,
        'startedAtElapsedNanos': 1000000000,
        'startedAtBootCount': 3,
        'endedAtElapsedNanos': 1000000000 + minutes * 60000000000,
        'endedAtBootCount': 3,
        'startSocPercent': 80,
        'endSocPercent': 40,
        'startOdometerKm': 1000,
        'endOdometerKm': 1080,
        'rollupTractionWh': 20.0 * minutes * 60 / 3600 * 1000,
        'rollupRegenWh': 0.0,
        'rollupAuxiliaryWh': 2.0 * minutes * 60 / 3600 * 1000,
        'rollupDistanceKm': 0.833 * minutes,
        'rollupIntegratedSeconds': minutes * 60.0,
      });
      for (var m = 0; m < minutes; m++) {
        await archive.upsertInterval({
          'sessionId': 'trip-1',
          'startUtcMillis': startMillis + m * 60000,
          'tractionWh': 20.0 * 60 / 3600 * 1000,
          'regeneratedWh': 0.0,
          'auxiliaryWh': 2.0 * 60 / 3600 * 1000,
          'integratedSeconds': 60.0,
          'speedDistanceKm': 0.833,
          'odometerDistanceKm': 0.833,
          'speedIntegratedSeconds': 60.0,
          'climateWh': 0.0,
          'climateIntegratedSeconds': 0.0,
        });
      }
    });
    await open(tester, archive);

    await scrollTo(tester, find.byType(EnergyBarChart));
    final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
    final width = tester.getSize(find.byType(EnergyBarChart)).width;
    const profile = AppSizes.chartBarProfile;
    expect(chart.bars.length, lessThan(minutes));
    expect(
      AppSizes.chartAxisGutter + profile.contentWidth(chart.bars.length),
      lessThanOrEqualTo(width),
    );

    // The wider column has to say so. The title names no interval any more,
    // and an unnamed column is read as the minute the car stores.
    expect(find.textContaining('min per column'), findsOneWidget);
  });

  testWidgets(
    'a 2025-stamped head minute stays beside its neighbours on the phone chart',
    (tester) async {
      // Nine recorded minutes; the first carries a boot-default stamp from
      // 2025 while the rest are a 2026 session. The phone must reduce by
      // ordinal against the session's own first minute, so the stray minute
      // draws adjacent to the others instead of fourteen months away — and
      // its label names a position, never a clock time the session does not
      // own.
      const minutes = 9;
      final archive = await real(tester, memoryArchive);
      await real(tester, () async {
        await archive.upsertTrip({
          'id': 'trip-1',
          'status': 'CLOSED',
          'startedAtUtcMillis': startMillis,
          'endedAtUtcMillis': startMillis + minutes * 60000,
          'startedAtElapsedNanos': 1000000000,
          'startedAtBootCount': 3,
          'endedAtElapsedNanos': 1000000000 + minutes * 60000000000,
          'endedAtBootCount': 3,
          'startSocPercent': 80,
          'endSocPercent': 75,
          'startOdometerKm': 1000,
          'endOdometerKm': 1005,
          'rollupTractionWh': 1200.0,
          'rollupRegenWh': 0.0,
          'rollupAuxiliaryWh': 120.0,
          'rollupDistanceKm': 5.0,
          'rollupIntegratedSeconds': minutes * 60.0,
        });
        for (var m = 0; m < minutes; m++) {
          await archive.upsertInterval({
            'sessionId': 'trip-1',
            'startUtcMillis': m == 0
                ? 1753168080000 // 2025-05-23 22:08:00 boot default
                : startMillis + m * 60000,
            'tractionWh': 20.0 * 60 / 3600 * 1000,
            'regeneratedWh': 0.0,
            'auxiliaryWh': 2.0 * 60 / 3600 * 1000,
            'integratedSeconds': 60.0,
            'speedDistanceKm': 0.833,
            'odometerDistanceKm': 0.833,
            'speedIntegratedSeconds': 60.0,
            'climateWh': 0.0,
            'climateIntegratedSeconds': 0.0,
          });
        }
      });
      await open(tester, archive);

      await scrollTo(tester, find.byType(EnergyBarChart));
      final chart = tester.widget<EnergyBarChart>(find.byType(EnergyBarChart));
      // Nine minutes, nine measured bars: the bogus stamp did not widen
      // anything, and no bar was dropped to a far-away slot.
      expect(chart.bars, hasLength(9));
      expect(chart.bars.every((bar) => bar.value.isFinite), isTrue);
    },
  );

  testWidgets('a drive with events displays the events timeline card', (
    tester,
  ) async {
    final archive = await archiveWith(tester, withCan: true);
    await real(tester, () async {
      await archive.upsertEvent({
        'id': 1,
        'sessionId': 'trip-1',
        'type': 'TRIP_STARTED',
        'occurredAtUtcMillis': startMillis,
        'details': '{}',
      });
      await archive.upsertEvent({
        'id': 2,
        'sessionId': 'trip-1',
        'type': 'TRIP_ENDED',
        'occurredAtUtcMillis': startMillis + 120000,
        'details': '{}',
      });
    });

    await open(tester, archive);
    await scrollTo(tester, find.text('Events'));
    expect(find.text('Events'), findsOneWidget);
    expect(find.text('Trip started'), findsOneWidget);
    expect(find.text('Trip ended'), findsOneWidget);
  });

  testWidgets('a drive without events hides the events card', (tester) async {
    final archive = await archiveWith(tester, withCan: true);
    await open(tester, archive);
    expect(find.text('Events'), findsNothing);
  });

  testWidgets(
    'a charge displays mosaic, charging power chart, energy balance, traces and events',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final archive = await real(tester, memoryArchive);
      await real(tester, () async {
        await archive.upsertCharge({
          'id': 'charge-1',
          'status': 'CLOSED',
          'startedAtUtcMillis': startMillis,
          'endedAtUtcMillis': startMillis + 180000,
          'startedAtElapsedNanos': 1000000000,
          'startedAtBootCount': 1,
          'endedAtElapsedNanos': 181000000000,
          'endedAtBootCount': 1,
          'startSocPercent': 30,
          'endSocPercent': 80,
          'startOdometerKm': 2000,
          'endOdometerKm': 2000,
          'costPerKwh': 1.50,
          'costCurrency': 'BRL',
          'startPlace': 'Home Wallbox',
          'startLatitude': -23.5505,
          'startLongitude': -46.6333,
        });
        for (var m = 0; m < 3; m++) {
          await archive.upsertInterval({
            'sessionId': 'charge-1',
            'startUtcMillis': startMillis + m * 60000,
            'deliveredWh': 1000.0,
            'integratedSeconds': 60.0,
            'climateWh': 100.0,
            'climateIntegratedSeconds': 60.0,
          });
        }
        await archive.upsertEvent({
          'id': 1,
          'sessionId': 'charge-1',
          'type': 'CHARGE_STARTED',
          'occurredAtUtcMillis': startMillis,
          'details': '{}',
        });
        await archive.upsertEvent({
          'id': 2,
          'sessionId': 'charge-1',
          'type': 'CHARGE_LIMIT_REACHED',
          'occurredAtUtcMillis': startMillis + 120000,
          'details': '{}',
        });
        await archive.upsertEvent({
          'id': 3,
          'sessionId': 'charge-1',
          'type': 'CHARGE_ENDED',
          'occurredAtUtcMillis': startMillis + 180000,
          'details': '{}',
        });
      });

      final chargeRecord = SessionRecord(
        id: 'charge-1',
        vehicleId: 'test',
        kind: SessionKind.charge,
        status: 'CLOSED',
        startedAtUtcMillis: startMillis,
        startedAtElapsedNanos: 1000000000,
        endedAtUtcMillis: startMillis + 180000,
        endedAtElapsedNanos: 181000000000,
        rollup: const SessionRollup(
          distance: Measurement.unreported(unit: 'km'),
          traction: Measurement.unreported(unit: 'Wh'),
          regen: Measurement.unreported(unit: 'Wh'),
          auxiliary: Measurement.unreported(unit: 'Wh'),
          climate: Measurement.unreported(unit: 'Wh'),
          delivered: Measurement.measured(3000, unit: 'Wh'),
          integratedSeconds: Measurement.measured(180, unit: 's'),
        ),
        startOdometer: const Measurement.measured(2000, unit: 'km'),
        endOdometer: const Measurement.measured(2000, unit: 'km'),
        startSoc: const Measurement.measured(30, unit: '%'),
        endSoc: const Measurement.measured(80, unit: '%'),
        minSoc: const Measurement.measured(30, unit: '%'),
        maxSoc: const Measurement.measured(80, unit: '%'),
        startAmbientTemp: const Measurement.measured(24, unit: '°C'),
        endAmbientTemp: const Measurement.measured(24, unit: '°C'),
        meanAmbientTemp: const Measurement.measured(24, unit: '°C'),
        startLatitude: -23.5505,
        startLongitude: -46.6333,
        costPerKwh: 1.50,
        costCurrency: 'BRL',
        startPlace: 'Home Wallbox',
        createdAtUtcMillis: startMillis,
        updatedAtUtcMillis: startMillis,
      );

      final store = SqfliteStore(archive.database);
      await tester.pumpWidget(
        host(ChargeDetailScreen(store: store, session: chargeRecord)),
      );
      await readsLand(tester);

      expect(find.text('Home Wallbox'), findsOneWidget);
      expect(find.text('Peak & average'), findsOneWidget);
      expect(find.text('3.00'), findsOneWidget);
      expect(find.text('Cost'), findsOneWidget);
      expect(find.text(r'$ 4.50'), findsOneWidget);

      await scrollTo(tester, find.text('Energy balance'));
      expect(find.text('Energy balance'), findsOneWidget);

      await scrollTo(tester, find.text('Charging power'));
      expect(find.text('Charging power'), findsOneWidget);
      expect(find.byType(EnergyBarChart), findsOneWidget);

      await scrollTo(tester, find.text('Events'));
      expect(find.text('Target charge reached'), findsOneWidget);
    },
  );

  testWidgets(
    'an unpriced charge displays cost card and tapping it opens keypad editor',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final archive = await real(tester, memoryArchive);
      await real(tester, () async {
        await archive.upsertCharge({
          'id': 'charge-2',
          'status': 'CLOSED',
          'startedAtUtcMillis': startMillis,
          'endedAtUtcMillis': startMillis + 60000,
          'startedAtElapsedNanos': 1000000000,
          'startedAtBootCount': 1,
          'endedAtElapsedNanos': 61000000000,
          'endedAtBootCount': 1,
          'startSocPercent': 50,
          'endSocPercent': 60,
          'startOdometerKm': 2000,
          'endOdometerKm': 2000,
        });
        await archive.upsertInterval({
          'sessionId': 'charge-2',
          'startUtcMillis': startMillis,
          'deliveredWh': 2000.0,
          'integratedSeconds': 60.0,
        });
      });

      final chargeRecord = SessionRecord(
        id: 'charge-2',
        vehicleId: 'test',
        kind: SessionKind.charge,
        status: 'CLOSED',
        startedAtUtcMillis: startMillis,
        startedAtElapsedNanos: 1000000000,
        endedAtUtcMillis: startMillis + 60000,
        endedAtElapsedNanos: 61000000000,
        rollup: const SessionRollup(
          distance: Measurement.unreported(unit: 'km'),
          traction: Measurement.unreported(unit: 'Wh'),
          regen: Measurement.unreported(unit: 'Wh'),
          auxiliary: Measurement.unreported(unit: 'Wh'),
          climate: Measurement.unreported(unit: 'Wh'),
          delivered: Measurement.measured(2000, unit: 'Wh'),
          integratedSeconds: Measurement.measured(60, unit: 's'),
        ),
        startOdometer: const Measurement.measured(2000, unit: 'km'),
        endOdometer: const Measurement.measured(2000, unit: 'km'),
        startSoc: const Measurement.measured(50, unit: '%'),
        endSoc: const Measurement.measured(60, unit: '%'),
        minSoc: const Measurement.measured(50, unit: '%'),
        maxSoc: const Measurement.measured(60, unit: '%'),
        startAmbientTemp: const Measurement.measured(22, unit: '°C'),
        endAmbientTemp: const Measurement.measured(22, unit: '°C'),
        meanAmbientTemp: const Measurement.measured(22, unit: '°C'),
        createdAtUtcMillis: startMillis,
        updatedAtUtcMillis: startMillis,
      );

      final store = SqfliteStore(archive.database);
      await tester.pumpWidget(
        host(ChargeDetailScreen(store: store, session: chargeRecord)),
      );
      await readsLand(tester);

      expect(find.text('Cost'), findsOneWidget);

      // Tap cost tile to open editor
      await tester.tap(find.text('Cost'));
      await tester.pumpAndSettle();

      expect(find.text('Charge price'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);

      // Tap Save to submit
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await readsLand(tester);
    },
  );

  testWidgets(
    'a charge with coordinates allows naming its place and updating the mosaic',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final archive = await real(tester, memoryArchive);
      await real(tester, () async {
        await archive.upsertCharge({
          'id': 'charge-3',
          'status': 'CLOSED',
          'startedAtUtcMillis': startMillis,
          'endedAtUtcMillis': startMillis + 60000,
          'startedAtElapsedNanos': 1000000000,
          'startedAtBootCount': 1,
          'endedAtElapsedNanos': 61000000000,
          'endedAtBootCount': 1,
          'startSocPercent': 50,
          'endSocPercent': 60,
          'startOdometerKm': 2000,
          'endOdometerKm': 2000,
          'startLatitude': -23.5505,
          'startLongitude': -46.6333,
        });
        await archive.upsertInterval({
          'sessionId': 'charge-3',
          'startUtcMillis': startMillis,
          'deliveredWh': 2000.0,
          'integratedSeconds': 60.0,
        });
      });

      final chargeRecord = SessionRecord(
        id: 'charge-3',
        vehicleId: 'test',
        kind: SessionKind.charge,
        status: 'CLOSED',
        startedAtUtcMillis: startMillis,
        startedAtElapsedNanos: 1000000000,
        endedAtUtcMillis: startMillis + 60000,
        endedAtElapsedNanos: 61000000000,
        rollup: const SessionRollup(
          distance: Measurement.unreported(unit: 'km'),
          traction: Measurement.unreported(unit: 'Wh'),
          regen: Measurement.unreported(unit: 'Wh'),
          auxiliary: Measurement.unreported(unit: 'Wh'),
          climate: Measurement.unreported(unit: 'Wh'),
          delivered: Measurement.measured(2000, unit: 'Wh'),
          integratedSeconds: Measurement.measured(60, unit: 's'),
        ),
        startOdometer: const Measurement.measured(2000, unit: 'km'),
        endOdometer: const Measurement.measured(2000, unit: 'km'),
        startSoc: const Measurement.measured(50, unit: '%'),
        endSoc: const Measurement.measured(60, unit: '%'),
        minSoc: const Measurement.measured(50, unit: '%'),
        maxSoc: const Measurement.measured(60, unit: '%'),
        startAmbientTemp: const Measurement.measured(22, unit: '°C'),
        endAmbientTemp: const Measurement.measured(22, unit: '°C'),
        meanAmbientTemp: const Measurement.measured(22, unit: '°C'),
        startLatitude: -23.5505,
        startLongitude: -46.6333,
        createdAtUtcMillis: startMillis,
        updatedAtUtcMillis: startMillis,
      );

      final store = SqfliteStore(archive.database);
      await tester.pumpWidget(
        host(ChargeDetailScreen(store: store, session: chargeRecord)),
      );
      await readsLand(tester);

      expect(find.text('Location'), findsOneWidget);
      expect(find.text('Name location'), findsOneWidget);

      // Tap location tile to open place dialog
      await tester.tap(find.text('Name location'));
      await tester.pumpAndSettle();

      expect(find.text('Name this place'), findsOneWidget);

      // Enter place name
      await tester.enterText(find.byType(TextField), 'Garagem de Casa');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await readsLand(tester);

      // The place should now be visible on the location tile
      expect(find.text('Garagem de Casa'), findsOneWidget);
    },
  );
}
