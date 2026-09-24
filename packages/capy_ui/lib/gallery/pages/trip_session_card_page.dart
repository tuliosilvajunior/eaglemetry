import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class TripSessionCardGalleryPage extends StatefulWidget {
  const TripSessionCardGalleryPage({super.key});

  @override
  State<TripSessionCardGalleryPage> createState() =>
      _TripSessionCardGalleryPageState();
}

enum _TripScenario { fullRoute, unnamedCoords, noGps }

class _TripSessionCardGalleryPageState
    extends State<TripSessionCardGalleryPage> {
  _TripScenario _scenario = _TripScenario.fullRoute;
  bool _selected = false;

  static SessionRecord _makeSession({
    required String id,
    required double distanceKm,
    required double tractionWh,
    required double regenWh,
  }) {
    return SessionRecord(
      id: id,
      vehicleId: 'car-1',
      kind: SessionKind.trip,
      status: 'CLOSED',
      startedAtUtcMillis: 1750000000000,
      startedAtElapsedNanos: 0,
      endedAtUtcMillis: 1750001800000,
      endedAtElapsedNanos: 1800000000000,
      durationMillis: 1800000,
      rollup: SessionRollup(
        distance: Measurement.measured(distanceKm, unit: 'km'),
        traction: Measurement.measured(tractionWh, unit: 'Wh'),
        regen: Measurement.measured(regenWh, unit: 'Wh'),
        auxiliary: const Measurement.measured(300.0, unit: 'Wh'),
        climate: const Measurement.unreported(unit: 'Wh'),
        delivered: const Measurement.unreported(unit: 'Wh'),
        integratedSeconds: const Measurement.measured(1800.0, unit: 's'),
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
      createdAtUtcMillis: 1750000000000,
      updatedAtUtcMillis: 1750001800000,
      noLongerReducible: true,
    );
  }

  static const _sampleRoute = [
    InsightPoint(-23.5505, -46.6333),
    InsightPoint(-23.5530, -46.6380),
    InsightPoint(-23.5570, -46.6430),
    InsightPoint(-23.5600, -46.6500),
  ];

  TripSessionEntry get _entry {
    switch (_scenario) {
      case _TripScenario.fullRoute:
        return TripSessionEntry(
          id: 'trip-1',
          startedAtUtcMillis: 1750000000000,
          endedAtUtcMillis: 1750001800000,
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
            id: 'trip-1',
            distanceKm: 14.5,
            tractionWh: 2500.0,
            regenWh: 400.0,
          ),
        );
      case _TripScenario.unnamedCoords:
        return TripSessionEntry(
          id: 'trip-2',
          startedAtUtcMillis: 1750000000000,
          endedAtUtcMillis: 1750003600000,
          durationMillis: 3600000,
          distanceKm: 42.0,
          netEnergyKwh: 7.1,
          avgSpeedKmh: 42.0,
          startLatitude: -23.5505,
          startLongitude: -46.6333,
          endLatitude: -23.5600,
          endLongitude: -46.6500,
          routePoints: _sampleRoute,
          session: _makeSession(
            id: 'trip-2',
            distanceKm: 42.0,
            tractionWh: 8100.0,
            regenWh: 1520.0,
          ),
        );
      case _TripScenario.noGps:
        return TripSessionEntry(
          id: 'trip-3',
          startedAtUtcMillis: 1750000000000,
          endedAtUtcMillis: 1750000900000,
          durationMillis: 900000,
          distanceKm: 5.2,
          netEnergyKwh: 0.9,
          avgSpeedKmh: 20.8,
          session: _makeSession(
            id: 'trip-3',
            distanceKm: 5.2,
            tractionWh: 950.0,
            regenWh: 100.0,
          ),
        );
    }
  }

  Widget _previewFrame({
    required String title,
    required String subtitle,
    required double width,
    required SurfaceCapabilities capabilities,
  }) {
    final colors = AppThemeColors.of(context);
    return Container(
      width: width,
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
          Padding(
            padding: const EdgeInsets.all(AppSpacing.x3),
            child: TripSessionCard(
              entry: _entry,
              capabilities: capabilities,
              selected: _selected,
              onTap: () => setState(() => _selected = !_selected),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compactCap = SurfaceCapabilities.fromWidth(360);
    final expandedCap = SurfaceCapabilities.fromWidth(720);

    return GalleryDemoPage(
      title: 'TripSessionCard',
      summary:
          'Adaptive trip card with static route preview, origin/destination timeline, and telemetry metrics.',
      note:
          'Adapts automatically based on SurfaceCapabilities: vertical stacked banner on phone (<600px), split thumbnail with metric stack on tablet/car (>=600px).',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Scenario & State',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TrackSegmentedControl<_TripScenario>(
                  items: const [
                    TabItem(
                      value: _TripScenario.fullRoute,
                      label: 'Named places',
                    ),
                    TabItem(
                      value: _TripScenario.unnamedCoords,
                      label: 'Coordinates',
                    ),
                    TabItem(value: _TripScenario.noGps, label: 'No GPS'),
                  ],
                  selected: _scenario,
                  onSelected: (val) => setState(() => _scenario = val),
                ),
                const SizedBox(height: AppSpacing.x3),
                SettingToggleRow(
                  label: 'Selected (Stage Focus)',
                  value: _selected,
                  onChanged: (val) => setState(() => _selected = val),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _previewFrame(
                  title: 'Compact Viewport (<600px)',
                  subtitle: 'Phone / 360px width banner layout',
                  width: 360,
                  capabilities: compactCap,
                ),
                const SizedBox(width: AppSpacing.x4),
                _previewFrame(
                  title: 'Expanded Viewport (>=600px)',
                  subtitle: 'Head Unit / Tablet split thumbnail layout',
                  width: 580,
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
