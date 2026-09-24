import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class TripsBodyGalleryPage extends StatefulWidget {
  const TripsBodyGalleryPage({super.key});

  @override
  State<TripsBodyGalleryPage> createState() => _TripsBodyGalleryPageState();
}

enum _BodyStateScenario { loaded, empty, loading, error }

class _TripsBodyGalleryPageState extends State<TripsBodyGalleryPage> {
  _BodyStateScenario _scenario = _BodyStateScenario.loaded;
  String? _selectedTripId;

  static SessionRecord _makeSession({
    required String id,
    required int startedAtUtcMillis,
    required int endedAtUtcMillis,
    required double distanceKm,
    required double tractionWh,
    required double regenWh,
  }) {
    return SessionRecord(
      id: id,
      vehicleId: 'car-1',
      kind: SessionKind.trip,
      status: 'CLOSED',
      startedAtUtcMillis: startedAtUtcMillis,
      startedAtElapsedNanos: 0,
      endedAtUtcMillis: endedAtUtcMillis,
      endedAtElapsedNanos: (endedAtUtcMillis - startedAtUtcMillis) * 1000000,
      durationMillis: endedAtUtcMillis - startedAtUtcMillis,
      rollup: SessionRollup(
        distance: Measurement.measured(distanceKm, unit: 'km'),
        traction: Measurement.measured(tractionWh, unit: 'Wh'),
        regen: Measurement.measured(regenWh, unit: 'Wh'),
        auxiliary: const Measurement.measured(300.0, unit: 'Wh'),
        climate: const Measurement.unreported(unit: 'Wh'),
        delivered: const Measurement.unreported(unit: 'Wh'),
        integratedSeconds: Measurement.measured(
          (endedAtUtcMillis - startedAtUtcMillis) / 1000.0,
          unit: 's',
        ),
      ),
      startOdometer: const Measurement.measured(1000.0, unit: 'km'),
      endOdometer: Measurement.measured(1000.0 + distanceKm, unit: 'km'),
      startSoc: const Measurement.measured(80.0, unit: '%'),
      endSoc: const Measurement.measured(68.0, unit: '%'),
      minSoc: const Measurement.measured(68.0, unit: '%'),
      maxSoc: const Measurement.measured(80.0, unit: '%'),
      startAmbientTemp: const Measurement.measured(22.0, unit: '°C'),
      endAmbientTemp: const Measurement.measured(22.0, unit: '°C'),
      meanAmbientTemp: const Measurement.measured(22.0, unit: '°C'),
      createdAtUtcMillis: startedAtUtcMillis,
      updatedAtUtcMillis: endedAtUtcMillis,
      noLongerReducible: true,
    );
  }

  static const _sampleRoute = [
    InsightPoint(-23.5505, -46.6333),
    InsightPoint(-23.5530, -46.6380),
    InsightPoint(-23.5570, -46.6430),
    InsightPoint(-23.5600, -46.6500),
  ];

  static List<TripSessionEntry> _makeTrips() {
    final now = DateTime.now();
    final todayStart1 = now
        .subtract(const Duration(hours: 2))
        .millisecondsSinceEpoch;
    final todayEnd1 = now
        .subtract(const Duration(hours: 1, minutes: 30))
        .millisecondsSinceEpoch;

    final todayStart2 = now
        .subtract(const Duration(hours: 6))
        .millisecondsSinceEpoch;
    final todayEnd2 = now
        .subtract(const Duration(hours: 5, minutes: 40))
        .millisecondsSinceEpoch;

    final yesterdayStart1 = now
        .subtract(const Duration(days: 1, hours: 4))
        .millisecondsSinceEpoch;
    final yesterdayEnd1 = now
        .subtract(const Duration(days: 1, hours: 3))
        .millisecondsSinceEpoch;

    return [
      // Today
      TripSessionEntry(
        id: 'trip-today-1',
        startedAtUtcMillis: todayStart1,
        endedAtUtcMillis: todayEnd1,
        durationMillis: 1800000,
        distanceKm: 14.5,
        netEnergyKwh: 2.4,
        avgSpeedKmh: 29.0,
        startPlace: 'Casa',
        endPlace: 'Trabalho',
        startLatitude: -23.5505,
        startLongitude: -46.6333,
        endLatitude: -23.5600,
        endLongitude: -46.6500,
        routePoints: _sampleRoute,
        session: _makeSession(
          id: 'trip-today-1',
          startedAtUtcMillis: todayStart1,
          endedAtUtcMillis: todayEnd1,
          distanceKm: 14.5,
          tractionWh: 2500.0,
          regenWh: 400.0,
        ),
      ),
      TripSessionEntry(
        id: 'trip-today-2',
        startedAtUtcMillis: todayStart2,
        endedAtUtcMillis: todayEnd2,
        durationMillis: 1200000,
        distanceKm: 8.2,
        netEnergyKwh: 1.3,
        avgSpeedKmh: 24.6,
        startPlace: 'Academia',
        endPlace: 'Casa',
        startLatitude: -23.5550,
        startLongitude: -46.6400,
        endLatitude: -23.5505,
        endLongitude: -46.6333,
        routePoints: _sampleRoute,
        session: _makeSession(
          id: 'trip-today-2',
          startedAtUtcMillis: todayStart2,
          endedAtUtcMillis: todayEnd2,
          distanceKm: 8.2,
          tractionWh: 1400.0,
          regenWh: 200.0,
        ),
      ),
      // Yesterday
      TripSessionEntry(
        id: 'trip-yesterday-1',
        startedAtUtcMillis: yesterdayStart1,
        endedAtUtcMillis: yesterdayEnd1,
        durationMillis: 3600000,
        distanceKm: 42.0,
        netEnergyKwh: 7.1,
        avgSpeedKmh: 42.0,
        startPlace: 'Trabalho',
        endPlace: 'Shopping',
        startLatitude: -23.5600,
        startLongitude: -46.6500,
        endLatitude: -23.5700,
        endLongitude: -46.6700,
        routePoints: _sampleRoute,
        session: _makeSession(
          id: 'trip-yesterday-1',
          startedAtUtcMillis: yesterdayStart1,
          endedAtUtcMillis: yesterdayEnd1,
          distanceKm: 42.0,
          tractionWh: 8100.0,
          regenWh: 1520.0,
        ),
      ),
    ];
  }

  Loadable<List<TripSessionEntry>> get _state {
    switch (_scenario) {
      case _BodyStateScenario.loaded:
        return Loadable.ready(_makeTrips());
      case _BodyStateScenario.empty:
        return const Loadable.ready(<TripSessionEntry>[]);
      case _BodyStateScenario.loading:
        return const Loadable.loading();
      case _BodyStateScenario.error:
        return const Loadable.failed(
          'Falha de conexão com a base de telemetria',
        );
    }
  }

  Widget _previewFrame({
    required String title,
    required String subtitle,
    required double width,
    required double height,
    required SurfaceCapabilities capabilities,
  }) {
    final colors = AppThemeColors.of(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppRadii.mdRadius,
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x3,
              vertical: AppSpacing.x2,
            ),
            decoration: BoxDecoration(
              color: colors.control,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadii.md),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.label),
                Text(
                  subtitle,
                  style: AppText.caption.copyWith(color: colors.inkMuted),
                ),
              ],
            ),
          ),
          Expanded(
            child: TripsBody(
              state: _state,
              capabilities: capabilities,
              selectedTripId: _selectedTripId,
              onSelectTrip: (trip) => setState(() {
                _selectedTripId = _selectedTripId == trip.id ? null : trip.id;
              }),
              onRetry: () =>
                  setState(() => _scenario = _BodyStateScenario.loaded),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compactCap = SurfaceCapabilities.fromWidth(390);
    final expandedCap = SurfaceCapabilities.fromWidth(680);

    return GalleryDemoPage(
      title: 'TripsBody',
      summary:
          'Shared platform-agnostic trip history body with day grouping sections, filter bar, and adaptive layout.',
      note:
          'Shared across Companion mobile phone app and Car head unit, handling data states (loading, empty, error, loaded) identically.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'State Scenario',
            child: TrackSegmentedControl<_BodyStateScenario>(
              items: const [
                TabItem(
                  value: _BodyStateScenario.loaded,
                  label: 'Loaded (Groups)',
                ),
                TabItem(value: _BodyStateScenario.empty, label: 'Empty'),
                TabItem(value: _BodyStateScenario.loading, label: 'Loading'),
                TabItem(value: _BodyStateScenario.error, label: 'Error'),
              ],
              selected: _scenario,
              onSelected: (val) => setState(() => _scenario = val),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _previewFrame(
                  title: 'Mobile Phone Layout (<600px)',
                  subtitle: 'Compact width 390px, vertical scroll',
                  width: 390,
                  height: 640,
                  capabilities: compactCap,
                ),
                const SizedBox(width: AppSpacing.x4),
                _previewFrame(
                  title: 'Car Head Unit / Tablet Layout (>=600px)',
                  subtitle: 'Expanded width 680px, landscape cards',
                  width: 680,
                  height: 640,
                  capabilities: expandedCap,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
