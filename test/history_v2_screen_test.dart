import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/mock_telemetry_store.dart';
import 'package:capy_energy/core/telemetry_api.dart';

import 'support/session_records.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/energy_session_panel.dart';
import 'package:capy_energy/screens_v2/history/battery_history_pane.dart';
import 'package:capy_energy/screens_v2/history/history_list.dart';
import 'package:capy_energy/screens_v2/history/history_v2_screen.dart';
import 'package:capy_energy/screens_v2/history/session_mosaic.dart';
import 'package:capy_ui/capy_ui.dart';

void main() {
  testWidgets('the rail opens trips first and switches to charges', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(HistoryV2Screen(title: 'History', telemetryApi: _FakeApi())),
    );
    await tester.pump();

    expect(find.byType(CategoryMenu<HistoryCategory>), findsOneWidget);
    expect(find.byType(TripHistoryPane), findsOneWidget);
    // 12.5 km driven, from the odometer pair.
    expect(find.byType(TripSessionCard), findsOneWidget);

    await tester.tap(find.text('Charging'));
    await tester.pump();
    await tester.pump();

    expect(find.byType(ChargeHistoryPane), findsOneWidget);
    expect(find.text('7.25 kWh'), findsOneWidget);

    // A charge opens on the same stage, with the readings a charge has.
    await tester.tap(find.text('7.25 kWh'));
    await tester.pumpAndSettle();

    expect(find.text('Energy added'), findsOneWidget);
    expect(find.text('Peak power'), findsOneWidget);
  });

  testWidgets('opening a session takes the detail fullscreen and back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(HistoryV2Screen(title: 'History', telemetryApi: _FakeApi())),
    );
    await tester.pumpAndSettle();

    final docked = tester.getTopLeft(
      find.byType(CategoryMenu<HistoryCategory>),
    );
    expect(docked.dx, greaterThanOrEqualTo(0));

    await tester.tap(find.byType(TripSessionCard).first);
    await tester.pumpAndSettle();

    // The list and its rail are shoved off the left edge, and the detail has
    // the stage.
    expect(
      tester.getTopLeft(find.byType(CategoryMenu<HistoryCategory>)).dx,
      lessThan(0),
    );
    expect(find.text('Drag down to close'), findsOneWidget);
    expect(find.text('Temperature'), findsOneWidget);
    expect(find.text('Climb'), findsOneWidget);
    expect(find.text('+320 m'), findsWidgets);
    expect(find.text('Home → Work'), findsOneWidget);
    expect(
      find.text(
        'This trip used 150.0 Wh/km more than your last 30 days (4 trips).',
      ),
      findsOneWidget,
    );

    // Dragging the expanded card down brings them back.
    await tester.drag(find.text('Drag down to close'), const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byType(CategoryMenu<HistoryCategory>)).dx,
      docked.dx,
    );
  });

  testWidgets('the route card is square, and grows upward over the ring', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(HistoryV2Screen(title: 'History', telemetryApi: _FakeApi())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TripSessionCard).first);
    await tester.pumpAndSettle();

    final docked = tester.getSize(find.byType(RouteMapCard));
    expect(docked.width, closeTo(docked.height, 0.01));
    expect(find.byType(EnergySessionPanel), findsOneWidget);
    final mosaic = tester.getRect(find.byType(SessionMosaic));

    await tester.tap(find.byIcon(Icons.open_in_full));
    await tester.pumpAndSettle();

    final open = tester.getSize(find.byType(RouteMapCard));
    // The room comes from the ring stacked above it in the same column: the
    // card grows upward, its column keeps its width, and the chart and the
    // wall of readings beside it do not move at all.
    expect(open.height, greaterThan(docked.height));
    expect(open.width, docked.width);
    expect(find.byType(EnergySessionPanel), findsNothing);
    expect(tester.getRect(find.byType(SessionMosaic)), mosaic);

    // And it hands the space back.
    await tester.tap(find.byIcon(Icons.close_fullscreen));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(RouteMapCard)), docked);
    expect(find.byType(EnergySessionPanel), findsOneWidget);
  });

  testWidgets('the route is coloured by speed, and says what that means', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(HistoryV2Screen(title: 'History', telemetryApi: _FakeApi())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TripSessionCard).first);
    await tester.pumpAndSettle();

    // The speed the car recorded per position has to survive the trip from
    // the DTO to the card, or the line is one flat colour.
    final card = tester.widget<RouteMapCard>(find.byType(RouteMapCard));
    expect(card.points.every((point) => point.speedKmh != null), isTrue);
    expect(find.text('Slow 20 km/h'), findsOneWidget);
    expect(find.text('Fast 60 km/h'), findsOneWidget);
  });

  testWidgets('tapping a column of a drive opens its reading', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(HistoryV2Screen(title: 'History', telemetryApi: _FakeApi())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TripSessionCard).first);
    await tester.pumpAndSettle();

    expect(find.byType(ChartTooltip), findsNothing);

    await tester.tap(find.byType(EnergyBarChart).first);
    await tester.pumpAndSettle();

    // 0.05 kWh drawn over the minute — 40 Wh of traction plus the 10 Wh
    // auxiliary share — and the 8 Wh regeneration measured against it.
    final tooltip = find.byType(ChartTooltip);
    expect(tooltip, findsOneWidget);
    expect(
      find.descendant(of: tooltip, matching: find.text('0.05')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tooltip, matching: find.text('+0.01 kWh')),
      findsOneWidget,
    );
  });

  testWidgets('tapping a column of a charge opens its reading', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(HistoryV2Screen(title: 'History', telemetryApi: _FakeApi())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Charging'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7.25 kWh'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(EnergyBarChart).first);
    await tester.pumpAndSettle();

    expect(find.byType(ChartTooltip), findsOneWidget);
  });

  testWidgets('a charge shows its position but cannot enlarge it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(HistoryV2Screen(title: 'History', telemetryApi: _FakeApi())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Charging'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7.25 kWh'));
    await tester.pumpAndSettle();

    expect(find.byType(RouteMapCard), findsOneWidget);
    expect(find.byIcon(Icons.open_in_full), findsNothing);
  });

  testWidgets('a session with no position shows no route card', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(
        HistoryV2Screen(
          title: 'History',
          telemetryApi: _FakeApi(hasGps: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TripSessionCard).first);
    await tester.pumpAndSettle();

    expect(find.byType(RouteMapCard), findsNothing);
  });

  testWidgets('a long history builds only the rows near the viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(
        HistoryV2Screen(
          title: 'History',
          telemetryApi: _FakeApi(
            trips: [for (var i = 0; i < 60; i++) _trip(id: 'trip-$i')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Every row prints the same distance, so counting that text counts the
    // rows that were actually built. A `Column` would materialise all 60
    // whatever the panel's height; the list builds what is visible plus the
    // cache extent.
    final built = tester.widgetList(find.byType(TripSessionCard)).length;
    expect(built, greaterThan(0));
    expect(built, lessThan(30));
  });

  testWidgets(
    'a car with no session says so instead of showing an empty list',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _app(
          HistoryV2Screen(
            title: 'History',
            telemetryApi: _FakeApi(trips: const []),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('The car has recorded no session yet.'), findsOneWidget);
    },
  );

  testWidgets('a past charge can be priced from its own wall of readings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeApi();

    await tester.pumpWidget(
      _app(HistoryV2Screen(title: 'History', telemetryApi: api)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Charging'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7.25 kWh'));
    await tester.pumpAndSettle();

    // The cost tile says it can be changed, and the readings beside it do not.
    expect(find.byIcon(Icons.edit), findsOneWidget);
    // Never priced, and the fake reports no default rate, so there is no cost.
    expect(find.text('--'), findsWidgets);

    await tester.tap(find.byIcon(Icons.edit));
    await tester.pumpAndSettle();
    expect(find.text('Charge price'), findsOneWidget);

    for (final digit in ['1', '2', '0']) {
      await tester.tap(find.widgetWithText(InkWell, digit));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('money-keypad-save')));
    await tester.pumpAndSettle();

    expect(api.costWrites, hasLength(1));
    expect(api.costWrites.single[0], 'charge-1');
    expect(api.costWrites.single[1], 1.20);
    // The total the reader did not type is sent back as it stands, because the
    // collector writes both columns in one statement.
    expect(api.costWrites.single[2], isNull);
    // The reply's session is what the wall redraws from. The row the reader
    // selected still holds the old price, so a refresh alone would put the
    // missing cost straight back.
    expect(find.text(r'$ 8.70'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a battery opens a card with what it ran, oldest first', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(HistoryV2Screen(title: 'History', telemetryApi: _FakeApi())),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Battery'));
    await tester.pumpAndSettle();

    expect(find.byType(BatteryHistoryPane), findsOneWidget);
    // A battery is not a session, and the empty stage asks in its own words.
    expect(find.text('Select a battery to see what it ran.'), findsOneWidget);

    // The newest battery, which is the open one.
    await tester.tap(find.text('#6'));
    await tester.pumpAndSettle();

    expect(find.text('What this battery ran'), findsOneWidget);
    // The story, in the order it happened: the sessions the fold counted, and
    // the ones retention has since deleted.
    final kinds = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .where(
          (label) => const {
            'Drive',
            'Charge',
            'Parked',
            'Session deleted',
          }.contains(label),
        )
        .toList();
    expect(kinds, isNotEmpty);
    expect(kinds, contains('Charge'));
    expect(kinds, contains('Session deleted'));

    // The drive the battery closed inside carries how much of it counted here.
    expect(find.text('45% of this battery'), findsOneWidget);
  });

  testWidgets('a frozen battery says its sessions are gone', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(HistoryV2Screen(title: 'History', telemetryApi: _FakeApi())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Battery'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('#1'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(BatteryHistoryPane),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('#1'));
    await tester.pumpAndSettle();

    // Retention deleted them before the app recorded what they were, so an
    // empty list is the answer rather than a shorter one.
    expect(
      find.text('The sessions of this battery were deleted.'),
      findsOneWidget,
    );
  });
}

Widget _app(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

class _FakeApi extends TelemetryApi {
  _FakeApi({List<SessionRecord>? trips, this.hasGps = true})
    : trips = trips ?? [_trip()],
      super(source: MockTelemetrySource(), store: MockTelemetryStore());

  final List<SessionRecord> trips;

  /// Whether the recorded sessions carry positions at all — GPS collection is
  /// a setting, so a session with no route is an ordinary case.
  final bool hasGps;

  /// The store's first question, over the rows this fake holds.
  @override
  Future<SessionListPage> listSessions({
    SessionFilter? filter,
    PageRequest? page,
  }) async {
    final sessions = filter?.kind == SessionKind.charge ? [_charge()] : trips;
    return SessionListPage(
      sessions: sessions,
      totalCount: sessions.length,
      page: page ?? const PageRequest(),
      hasMore: false,
    );
  }

  /// The store's second question. The charge carries the price it was last
  /// written with, which is what lets a re-read show a new figure.
  @override
  Future<SessionDetail?> getSession(String id) async {
    final track = hasGps
        ? TrackCodec.encode(const [
            TrackPoint(
              latitude: -10.18,
              longitude: -48.33,
              tSeconds: 0,
              speedKmh: 10,
              altitudeM: 700,
            ),
            TrackPoint(
              latitude: -10.185,
              longitude: -48.335,
              tSeconds: 60,
              speedKmh: 30,
              altitudeM: 860,
            ),
            TrackPoint(
              latitude: -10.19,
              longitude: -48.34,
              tSeconds: 120,
              speedKmh: 90,
              altitudeM: 1020,
            ),
          ])
        : null;
    return SessionDetail(
      session: id == 'charge-1'
          ? _charge(costPerKwh: writtenCostPerKwh, currency: writtenCurrency)
          : trips.firstWhere(
              (trip) => trip.id == id,
              orElse: () => trips.first,
            ),
      events: const [],
      track: track,
    );
  }

  /// The store's third question: one stored minute.
  @override
  Future<TelemetrySeries> getSeries(
    String id, {
    Set<String>? keys,
    int? widthMillis,
  }) async {
    if (id == 'charge-1') {
      return TelemetrySeries(
        sessionId: id,
        intervals: [
          for (var minute = 0; minute < 30; minute++)
            intervalRecord(
              sessionId: id,
              startUtcMillis: 1770010000000 + minute * 60000,
              deliveredWh: (minute == 0 ? 7.4 : 6.9) * 1000 / 60,
              deliveredCoveredSeconds: 60,
              startSoc: 40 + minute / 30 * 20,
              endSoc: 40 + (minute + 1) / 30 * 20,
            ),
        ],
      );
    }
    return TelemetrySeries(
      sessionId: id,
      intervals: [
        intervalRecord(
          sessionId: id,
          startUtcMillis: 1770000000000,
          tractionWh: 40.0,
          regenWh: 8.0,
          auxiliaryWh: 10.0,
          distanceKm: 12.5,
        ),
      ],
    );
  }

  @override
  Future<InsightTripsResult> getInsightTrips({String? subjectId}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    const day = 86400000;
    InsightTrip row(
      String id, {
      required double distanceKm,
      required double canPackWh,
      required int daysAgo,
    }) {
      return InsightTrip(
        id: id,
        endedAtUtcMillis: now - daysAgo * day,
        distanceKm: distanceKm,
        canPackWh: canPackWh,
        hasMinuteBuckets: true,
        canAgreesWithSoc: true,
        aggregationVersion: 2,
      );
    }

    return InsightTripsResult(
      subjectId: subjectId,
      trips: [
        InsightTrip(
          id: 'trip-1',
          endedAtUtcMillis: now - day,
          distanceKm: 12.5,
          canPackWh: 3125,
          hasMinuteBuckets: true,
          canAgreesWithSoc: true,
          aggregationVersion: 2,
          startLatitude: -10.18,
          startLongitude: -48.33,
          endLatitude: -10.19,
          endLongitude: -48.34,
          path: '-10.18,-48.33;-10.19,-48.34',
        ),
        row('ref-1', distanceKm: 10, canPackWh: 1000, daysAgo: 2),
        row('ref-2', distanceKm: 10, canPackWh: 1000, daysAgo: 3),
        row('ref-3', distanceKm: 10, canPackWh: 1000, daysAgo: 4),
        row('ref-4', distanceKm: 10, canPackWh: 1000, daysAgo: 5),
      ],
    );
  }

  @override
  Future<InsightPlacesResult> getInsightPlaces() async {
    return const InsightPlacesResult(
      places: [
        InsightPlace(
          id: 'home',
          name: 'Home',
          latitude: -10.18,
          longitude: -48.33,
        ),
        InsightPlace(
          id: 'work',
          name: 'Work',
          latitude: -10.19,
          longitude: -48.34,
        ),
      ],
    );
  }

  /// One row per price write: session, rate, total, currency.
  final List<List<Object?>> costWrites = [];

  /// No default rate, so an unpriced charge shows no cost at all and the
  /// keypad opens on nothing rather than on a figure from Settings.
  @override
  Future<TelemetrySettingsResult> getTelemetrySettings() async {
    return TelemetrySettingsResult.fromMap(const {'chargeCostCurrency': 'BRL'});
  }

  @override
  Future<ChargeSessionCostUpdateResult> updateChargeSessionCost({
    required String sessionId,
    double? costPerKwh,
    double? paidAmount,
    String currency = 'BRL',
  }) async {
    costWrites.add([sessionId, costPerKwh, paidAmount, currency]);
    // The store holds the price after the write, which is where the card
    // re-reads it from.
    writtenCostPerKwh = costPerKwh;
    writtenCurrency = currency;
    return const ChargeSessionCostUpdateResult(
      ok: true,
      updatedRows: 1,
      session: null,
    );
  }

  /// The price the last write left on the charge.
  double? writtenCostPerKwh;
  String writtenCurrency = 'BRL';
}

SessionRecord _trip({String id = 'trip-1'}) => tripRecord(
  id: id,
  startedAtUtcMillis: 1770000000000,
  startedAtElapsedNanos: 1000000000,
  endedAtUtcMillis: 1770001800000,
  endedAtElapsedNanos: 1801000000000,
  startSoc: 80.0,
  endSoc: 74.0,
  startOdometerKm: 1000.0,
  endOdometerKm: 1012.5,
  meanAmbientTempC: 22.0,
  climbM: 320.0,
  sessionRollup: rollup(
    distanceKm: 12.5,
    tractionWh: 2400.0,
    regenWh: 800.0,
    auxiliaryWh: 800.0,
    integratedSeconds: 1800.0,
  ),
);

SessionRecord _charge({double? costPerKwh, String currency = 'BRL'}) =>
    chargeRecord(
      id: 'charge-1',
      status: 'ENDED',
      startedAtUtcMillis: 1770010000000,
      startedAtElapsedNanos: 1000000000,
      plugDisconnectedAtUtcMillis: 1770011800000,
      plugDisconnectedAtElapsedNanos: 1801000000000,
      startSoc: 40.0,
      endSoc: 60.0,
      deliveredWh: 7250.0,
      costPerKwh: costPerKwh,
      costCurrency: currency,
      startLatitude: -10.18,
      startLongitude: -48.33,
    );
