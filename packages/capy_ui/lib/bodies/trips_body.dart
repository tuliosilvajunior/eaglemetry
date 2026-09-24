import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../components/day_section_header.dart';
import '../components/trip_session_card.dart';
import '../components/trips_filter_bar.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'surface_capabilities.dart';

/// Shared, platform-agnostic body for the Trip History screen.
///
/// Reacts to:
/// - data state: [state] ([Loadable<List<TripSessionEntry>>])
/// - viewport width: [capabilities.widthClass]
///
/// Pure presentation component: does not query stores or navigate directly.
class TripsBody extends StatefulWidget {
  const TripsBody({
    required this.state,
    required this.capabilities,
    this.onSelectTrip,
    this.selectedTripId,
    this.onRetry,
    this.distanceUnit = 'km',
    this.energyUnit = 'kWh',
    this.speedUnit = 'km/h',
    this.filter = const TripsFilter(),
    this.onFilterChanged,
    this.emptyMessage = 'Nenhuma viagem registrada',
    this.emptyFilterMessage = 'Nenhuma viagem encontrada para este filtro',
    super.key,
  });

  final Loadable<List<TripSessionEntry>> state;
  final SurfaceCapabilities capabilities;
  final ValueChanged<TripSessionEntry>? onSelectTrip;
  final String? selectedTripId;
  final VoidCallback? onRetry;
  final String distanceUnit;
  final String energyUnit;
  final String speedUnit;
  final TripsFilter filter;
  final ValueChanged<TripsFilter>? onFilterChanged;
  final String emptyMessage;
  final String emptyFilterMessage;

  @override
  State<TripsBody> createState() => _TripsBodyState();
}

class _TripsBodyState extends State<TripsBody> {
  late TripsFilter _filter;

  @override
  void initState() {
    super.initState();
    _filter = widget.filter;
  }

  @override
  void didUpdateWidget(covariant TripsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filter != oldWidget.filter) {
      _filter = widget.filter;
    }
  }

  void _handleFilterChanged(TripsFilter newFilter) {
    setState(() {
      _filter = newFilter;
    });
    widget.onFilterChanged?.call(newFilter);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);

    if (widget.state.isFirstLoad) {
      return Center(child: CircularProgressIndicator(color: colors.ink));
    }

    if (widget.state.isEmptyFailure) {
      return Center(
        child: Padding(
          padding: AppSpacing.cardPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: colors.energy.critical,
              ),
              const SizedBox(height: AppSpacing.x3),
              Text(
                widget.state.errorMessage ?? 'Erro ao carregar viagens',
                style: AppText.body.copyWith(color: colors.ink),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.x4),
              if (widget.onRetry != null)
                ElevatedButton(
                  onPressed: widget.onRetry,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.selectionFill,
                    foregroundColor: colors.onSelection,
                    shape: RoundedRectangleBorder(
                      borderRadius: AppRadii.lgRadius,
                    ),
                  ),
                  child: const Text('Tentar novamente'),
                ),
            ],
          ),
        ),
      );
    }

    final allEntries = widget.state.value ?? const [];
    if (allEntries.isEmpty) {
      return Center(
        child: Padding(
          padding: AppSpacing.cardPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.route_outlined, size: 48, color: colors.inkMuted),
              const SizedBox(height: AppSpacing.x3),
              Text(
                widget.emptyMessage,
                style: AppText.body.copyWith(color: colors.inkMuted),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final filteredEntries = _filter.apply(allEntries);
    final dayGroups = assembleTripDayGroups(filteredEntries);

    final horizontalPadding =
        widget.capabilities.widthClass == SurfaceWidthClass.compact
        ? AppSpacing.x3
        : AppSpacing.x5;

    return Material(
      color: Colors.transparent,
      child: ListView(
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: AppSpacing.x3,
        ),
        children: [
          // Filter bar
          TripsFilterBar(
            filter: _filter,
            onFilterChanged: _handleFilterChanged,
          ),
          const SizedBox(height: AppSpacing.x3),

          if (dayGroups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.x8),
              child: Center(
                child: Text(
                  widget.emptyFilterMessage,
                  style: AppText.body.copyWith(color: colors.inkMuted),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            for (final group in dayGroups) ...[
              DaySectionHeader(
                group: group,
                distanceUnit: widget.distanceUnit,
                energyUnit: widget.energyUnit,
              ),
              const SizedBox(height: AppSpacing.x2),
              for (final trip in group.trips) ...[
                TripSessionCard(
                  entry: trip,
                  capabilities: widget.capabilities,
                  selected: widget.selectedTripId == trip.id,
                  onTap: () => widget.onSelectTrip?.call(trip),
                  distanceUnit: widget.distanceUnit,
                  energyUnit: widget.energyUnit,
                  speedUnit: widget.speedUnit,
                ),
                const SizedBox(height: AppSpacing.x3),
              ],
              const SizedBox(height: AppSpacing.x2),
            ],
        ],
      ),
    );
  }
}
