import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// Filter bar for the trip list, offering timeframe presets and location search.
class TripsFilterBar extends StatefulWidget {
  const TripsFilterBar({
    required this.filter,
    required this.onFilterChanged,
    this.searchHint,
    this.showTimePresets = false,
    this.allLabel,
    this.days7Label,
    this.days30Label,
    super.key,
  });

  final TripsFilter filter;
  final ValueChanged<TripsFilter> onFilterChanged;
  final String? searchHint;
  final bool showTimePresets;
  final String? allLabel;
  final String? days7Label;
  final String? days30Label;

  @override
  State<TripsFilterBar> createState() => _TripsFilterBarState();
}

class _TripsFilterBarState extends State<TripsFilterBar> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(text: widget.filter.query);
  }

  @override
  void didUpdateWidget(covariant TripsFilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filter.query != _searchController.text) {
      _searchController.text = widget.filter.query;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onPresetSelected(TripsTimePreset preset) {
    widget.onFilterChanged(
      TripsFilter(
        timePreset: preset,
        query: widget.filter.query,
        fromUtcMillis: widget.filter.fromUtcMillis,
        toUtcMillis: widget.filter.toUtcMillis,
      ),
    );
  }

  void _onQueryChanged(String query) {
    widget.onFilterChanged(
      TripsFilter(
        timePreset: widget.filter.timePreset,
        query: query,
        fromUtcMillis: widget.filter.fromUtcMillis,
        toUtcMillis: widget.filter.toUtcMillis,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final locale = Localizations.maybeLocaleOf(context)?.languageCode ?? 'pt';

    final effectiveHint =
        widget.searchHint ??
        switch (locale) {
          'en' => 'Search by location...',
          'es' => 'Buscar por ubicación...',
          'ru' => 'Поиск по местоположению...',
          _ => 'Buscar por local...',
        };
    final effectiveAll =
        widget.allLabel ??
        switch (locale) {
          'en' => 'All',
          'es' => 'Todas',
          'ru' => 'Все',
          _ => 'Todas',
        };
    final effective7Days =
        widget.days7Label ??
        switch (locale) {
          'en' => '7 days',
          'es' => '7 días',
          'ru' => '7 дней',
          _ => '7 dias',
        };
    final effective30Days =
        widget.days30Label ??
        switch (locale) {
          'en' => '30 days',
          'es' => '30 días',
          'ru' => '30 дней',
          _ => '30 dias',
        };

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Search text input
        Material(
          color: colors.control,
          borderRadius: AppRadii.lgRadius,
          child: Container(
            constraints: const BoxConstraints(
              minHeight: AppSizes.minTouchTarget,
            ),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x3),
            child: Row(
              children: [
                Icon(Icons.search, size: 20, color: colors.inkMuted),
                const SizedBox(width: AppSpacing.x2),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: _onQueryChanged,
                    style: AppText.body.copyWith(color: colors.ink),
                    decoration: InputDecoration(
                      hintText: effectiveHint,
                      hintStyle: AppText.body.copyWith(color: colors.inkSubtle),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                if (_searchController.text.isNotEmpty)
                  GestureDetector(
                    onTap: () {
                      _searchController.clear();
                      _onQueryChanged('');
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.x2),
                      child: Icon(
                        Icons.clear,
                        size: 18,
                        color: colors.inkMuted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (widget.showTimePresets) ...[
          const SizedBox(height: AppSpacing.x2),
          // Preset chips row
          Row(
            children: [
              _PresetChip(
                label: effectiveAll,
                selected: widget.filter.timePreset == TripsTimePreset.all,
                onTap: () => _onPresetSelected(TripsTimePreset.all),
              ),
              const SizedBox(width: AppSpacing.x2),
              _PresetChip(
                label: effective7Days,
                selected: widget.filter.timePreset == TripsTimePreset.days7,
                onTap: () => _onPresetSelected(TripsTimePreset.days7),
              ),
              const SizedBox(width: AppSpacing.x2),
              _PresetChip(
                label: effective30Days,
                selected: widget.filter.timePreset == TripsTimePreset.days30,
                onTap: () => _onPresetSelected(TripsTimePreset.days30),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final bg = selected ? colors.selectionFill : colors.control;
    final fg = selected ? colors.onSelection : colors.inkMuted;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.x3,
              vertical: AppSpacing.x1,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: AppRadii.fullRadius,
            ),
            child: Text(
              label,
              style: AppText.caption.copyWith(
                color: fg,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
