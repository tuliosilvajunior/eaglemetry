import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../components/app_card.dart';
import '../components/soft_action_tile.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'surface_capabilities.dart';

/// Shared, platform-agnostic body for the "Consultar locais" screen.
///
/// Handles three reactivity axes:
/// - data-reactive via [state] ([Loadable<PlacesData>])
/// - viewport-reactive via [capabilities.widthClass]
/// - input-reactive via [capabilities.allowKeyboard] / [inputMode]
///
/// Never calls Navigator or reads a store directly.
class PlacesBody extends StatelessWidget {
  const PlacesBody({
    required this.state,
    required this.capabilities,
    required this.isOptIn,
    this.onOpenSettings,
    this.onRetry,
    this.onSelectNamed,
    this.onSelectCandidate,
    this.onMergePlaces,
    this.enableSuggest = false,
    this.onSuggest,
    this.onSuggestNamed,
    this.onSuggestCandidate,
    this.suggestManualPrompt =
        'Não foi possível obter o endereço. Digite manualmente.',
    this.autoLoadingNamedIds = const {},
    this.autoLoadingCandidateIds = const {},
    super.key,
  });

  final Loadable<PlacesData> state;
  final SurfaceCapabilities capabilities;
  final bool isOptIn;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onRetry;
  final ValueChanged<NamedPlaceEntry>? onSelectNamed;
  final ValueChanged<CandidatePlace>? onSelectCandidate;

  /// Called when the driver taps Mesclar on a near-duplicate banner row.
  final ValueChanged<PlaceDuplicatePair>? onMergePlaces;

  /// Companion-only suggest. When true and [onSuggest] non-null, rows show "Sugerir".
  final bool enableSuggest;
  final Future<String?> Function(double latitude, double longitude)? onSuggest;
  final void Function(NamedPlaceEntry entry, String suggestedName)?
  onSuggestNamed;
  final void Function(CandidatePlace candidate, String suggestedName)?
  onSuggestCandidate;
  final String suggestManualPrompt;

  /// Auto-naming in progress per row. Shows loading spinner while waiting
  /// for Nominatim (15 req/min).
  final Set<String> autoLoadingNamedIds;
  final Set<String> autoLoadingCandidateIds;

  static const String attribution = '© OpenStreetMap contributors';
  static const String emptyNoGps =
      'Nenhum local visitado ainda — faca um Trip com GPS';
  static const String emptyAllNamed = 'Todos os locais ja tem nome';
  static const String optInBannerTitle = 'Sugestões de nome desativadas';
  static const String optInBannerMessage =
      'Ative as sugestões para ver nomes sugeridos via OpenStreetMap.';
  static const String optInBannerAction = 'Ativar sugestões';
  static const String namedSectionTitle = 'Nomeados';
  static const String unnamedSectionTitle = 'Sem nome';
  static const String loadingLabel = 'Carregando locais…';
  static const String duplicatesBannerTitle = 'Duplicatas proximas';
  static const String duplicatesMergeLabel = 'Mesclar';

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);

    // Data-reactive: loading / error / ready
    if (state.isFirstLoad) {
      return Center(
        key: const Key('places-loading'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: AppSpacing.x3),
            Text(
              loadingLabel,
              style: AppText.body.copyWith(color: colors.inkMuted),
            ),
            Text(
              attribution,
              style: AppText.caption.copyWith(color: colors.inkSubtle),
            ),
          ],
        ),
      );
    }

    if (state.isEmptyFailure) {
      return _ErrorState(
        message: state.errorMessage ?? 'Falha ao carregar locais',
        attribution: attribution,
        onRetry: onRetry,
        colors: colors,
      );
    }

    final data = state.value;
    if (data == null) {
      return Center(
        key: const Key('places-loading'),
        child: const CircularProgressIndicator(),
      );
    }

    // Empty: no GPS trips at all
    if (data.isEmpty) {
      return _EmptyNoGpsState(
        isOptIn: isOptIn,
        onOpenSettings: onOpenSettings,
        attribution: attribution,
        colors: colors,
      );
    }

    // Non-empty: build sections
    final isCompact = capabilities.widthClass == SurfaceWidthClass.compact;

    final banner = !isOptIn
        ? _OptInBanner(onOpenSettings: onOpenSettings, colors: colors)
        : null;

    final duplicates = data.duplicatePairs.isEmpty
        ? null
        : _DuplicatesBanner(
            pairs: data.duplicatePairs,
            onMergePlaces: onMergePlaces,
            colors: colors,
          );

    final namedSection = _NamedSection(
      entries: data.named,
      onSelectNamed: onSelectNamed,
      colors: colors,
      enableSuggest: enableSuggest,
      onSuggest: onSuggest,
      onSuggestNamed: onSuggestNamed,
      suggestManualPrompt: suggestManualPrompt,
      autoLoadingIds: autoLoadingNamedIds,
    );

    final bool hasCandidates = data.candidates.isNotEmpty;
    final Widget unnamedSection = hasCandidates
        ? _UnnamedSection(
            candidates: data.candidates,
            onSelectCandidate: onSelectCandidate,
            colors: colors,
            enableSuggest: enableSuggest,
            onSuggest: onSuggest,
            onSuggestCandidate: onSuggestCandidate,
            suggestManualPrompt: suggestManualPrompt,
            autoLoadingIds: autoLoadingCandidateIds,
          )
        : _AllNamedEmptySection(colors: colors);

    final attributionWidget = Padding(
      padding: const EdgeInsets.only(top: AppSpacing.x4, bottom: AppSpacing.x2),
      child: Text(
        attribution,
        key: const Key('places-attribution'),
        style: AppText.caption.copyWith(color: colors.inkSubtle),
        textAlign: TextAlign.center,
      ),
    );

    final content = isCompact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (banner != null) ...[
                banner,
                const SizedBox(height: AppSpacing.x4),
              ],
              if (duplicates != null) ...[
                duplicates,
                const SizedBox(height: AppSpacing.x4),
              ],
              namedSection,
              const SizedBox(height: AppSpacing.x4),
              unnamedSection,
              attributionWidget,
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (banner != null) ...[
                banner,
                const SizedBox(height: AppSpacing.x4),
              ],
              if (duplicates != null) ...[
                duplicates,
                const SizedBox(height: AppSpacing.x4),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: namedSection),
                  const SizedBox(width: AppSpacing.x4),
                  Expanded(child: unnamedSection),
                ],
              ),
              attributionWidget,
            ],
          );

    return SingleChildScrollView(
      key: const Key('places-body'),
      padding: const EdgeInsets.all(AppSpacing.x4),
      child: content,
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.attribution,
    required this.colors,
    this.onRetry,
  });

  final String message;
  final String attribution;
  final AppThemeColors colors;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('places-error'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: colors.inkSubtle),
            const SizedBox(height: AppSpacing.x3),
            Text(
              message,
              style: AppText.body.copyWith(color: colors.inkMuted),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: AppSpacing.x4),
              SoftActionTile(
                key: const Key('places-retry'),
                label: 'Tentar novamente',
                icon: Icons.refresh,
                onPressed: onRetry,
              ),
            ],
            const SizedBox(height: AppSpacing.x4),
            Text(
              attribution,
              key: const Key('places-attribution'),
              style: AppText.caption.copyWith(color: colors.inkSubtle),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyNoGpsState extends StatelessWidget {
  const _EmptyNoGpsState({
    required this.isOptIn,
    required this.attribution,
    required this.colors,
    this.onOpenSettings,
  });

  final bool isOptIn;
  final String attribution;
  final AppThemeColors colors;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('places-empty-no-gps'),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!isOptIn) ...[
              _OptInBanner(onOpenSettings: onOpenSettings, colors: colors),
              const SizedBox(height: AppSpacing.x4),
            ],
            Icon(Icons.location_off, size: 48, color: colors.inkSubtle),
            const SizedBox(height: AppSpacing.x3),
            Text(
              PlacesBody.emptyNoGps,
              style: AppText.body.copyWith(color: colors.inkMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.x4),
            Text(
              attribution,
              key: const Key('places-attribution'),
              style: AppText.caption.copyWith(color: colors.inkSubtle),
            ),
          ],
        ),
      ),
    );
  }
}

class _AllNamedEmptySection extends StatelessWidget {
  const _AllNamedEmptySection({required this.colors});

  final AppThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: const Key('places-unnamed-empty'),
      title: PlacesBody.unnamedSectionTitle,
      child: Text(
        PlacesBody.emptyAllNamed,
        style: AppText.body.copyWith(color: colors.inkMuted),
      ),
    );
  }
}

class _OptInBanner extends StatelessWidget {
  const _OptInBanner({required this.colors, this.onOpenSettings});

  final AppThemeColors colors;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: const Key('places-optin-banner'),
      title: PlacesBody.optInBannerTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            PlacesBody.optInBannerMessage,
            style: AppText.body.copyWith(color: colors.inkMuted),
          ),
          const SizedBox(height: AppSpacing.x3),
          SoftActionTile(
            key: const Key('places-optin-cta'),
            label: PlacesBody.optInBannerAction,
            icon: Icons.settings,
            onPressed: onOpenSettings,
          ),
          const SizedBox(height: AppSpacing.x2),
          Text(
            PlacesBody.attribution,
            style: AppText.caption.copyWith(color: colors.inkSubtle),
          ),
        ],
      ),
    );
  }
}

class _DuplicatesBanner extends StatelessWidget {
  const _DuplicatesBanner({
    required this.pairs,
    required this.colors,
    this.onMergePlaces,
  });

  final List<PlaceDuplicatePair> pairs;
  final AppThemeColors colors;
  final ValueChanged<PlaceDuplicatePair>? onMergePlaces;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: const Key('places-duplicates-banner'),
      title: PlacesBody.duplicatesBannerTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final pair in pairs)
            _DuplicateRow(
              pair: pair,
              colors: colors,
              onMerge: onMergePlaces == null
                  ? null
                  : () => onMergePlaces!(pair),
            ),
        ],
      ),
    );
  }
}

class _DuplicateRow extends StatelessWidget {
  const _DuplicateRow({required this.pair, required this.colors, this.onMerge});

  final PlaceDuplicatePair pair;
  final AppThemeColors colors;
  final VoidCallback? onMerge;

  String _label(InsightPlace place) {
    final display = place.displayName.trim();
    return display.isEmpty ? place.id : display;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
      child: Row(
        children: [
          Icon(Icons.copy_all_rounded, size: 16, color: colors.energy.warning),
          const SizedBox(width: AppSpacing.x2),
          Expanded(
            child: Text(
              '${_label(pair.placeA)} e ${_label(pair.placeB)}'
              ' — ${pair.distanceM.round()} m',
              key: Key(
                'places-duplicate-row-${pair.placeA.id}'
                '-${pair.placeB.id}',
              ),
              style: AppText.body.copyWith(color: colors.inkMuted),
            ),
          ),
          if (onMerge != null) ...[
            const SizedBox(width: AppSpacing.x2),
            Flexible(
              child: SoftActionTile(
                key: Key(
                  'places-duplicate-merge-${pair.placeA.id}-${pair.placeB.id}',
                ),
                label: PlacesBody.duplicatesMergeLabel,
                icon: Icons.merge,
                onPressed: onMerge,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NamedSection extends StatelessWidget {
  const _NamedSection({
    required this.entries,
    required this.colors,
    this.onSelectNamed,
    this.enableSuggest = false,
    this.onSuggest,
    this.onSuggestNamed,
    this.suggestManualPrompt =
        'Não foi possível obter o endereço. Digite manualmente.',
    this.autoLoadingIds = const {},
  });

  final List<NamedPlaceEntry> entries;
  final AppThemeColors colors;
  final ValueChanged<NamedPlaceEntry>? onSelectNamed;
  final bool enableSuggest;
  final Future<String?> Function(double latitude, double longitude)? onSuggest;
  final void Function(NamedPlaceEntry entry, String suggestedName)?
  onSuggestNamed;
  final String suggestManualPrompt;
  final Set<String> autoLoadingIds;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: const Key('places-named-section'),
      title: PlacesBody.namedSectionTitle,
      child: entries.isEmpty
          ? Text(
              'Nenhum local nomeado ainda',
              style: AppText.body.copyWith(color: colors.inkMuted),
            )
          : Column(
              children: [
                for (final entry in entries)
                  _NamedRow(
                    entry: entry,
                    colors: colors,
                    onTap: onSelectNamed,
                    enableSuggest: enableSuggest,
                    onSuggest: onSuggest,
                    onSuggestNamed: onSuggestNamed,
                    suggestManualPrompt: suggestManualPrompt,
                    isAutoLoading: autoLoadingIds.contains(entry.place.id),
                  ),
              ],
            ),
    );
  }
}

class _NamedRow extends StatefulWidget {
  const _NamedRow({
    required this.entry,
    required this.colors,
    this.onTap,
    this.enableSuggest = false,
    this.onSuggest,
    this.onSuggestNamed,
    this.suggestManualPrompt =
        'Não foi possível obter o endereço. Digite manualmente.',
    this.isAutoLoading = false,
  });

  final NamedPlaceEntry entry;
  final AppThemeColors colors;
  final ValueChanged<NamedPlaceEntry>? onTap;
  final bool enableSuggest;
  final Future<String?> Function(double latitude, double longitude)? onSuggest;
  final void Function(NamedPlaceEntry entry, String suggestedName)?
  onSuggestNamed;
  final String suggestManualPrompt;
  final bool isAutoLoading;

  @override
  State<_NamedRow> createState() => _NamedRowState();
}

class _NamedRowState extends State<_NamedRow> {
  bool _isSuggesting = false;
  String? _suggestError;

  bool get _shouldShowSuggest {
    if (!widget.enableSuggest) return false;
    if (widget.onSuggest == null || widget.onSuggestNamed == null) return false;
    final auto = widget.entry.place.autoName?.trim();
    return auto == null || auto.isEmpty;
  }

  Future<void> _handleSuggest() async {
    final fetcher = widget.onSuggest;
    if (fetcher == null) return;
    setState(() {
      _isSuggesting = true;
      _suggestError = null;
    });
    String? result;
    try {
      result = await fetcher(
        widget.entry.place.latitude,
        widget.entry.place.longitude,
      );
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    if (result == null || result.trim().isEmpty) {
      setState(() {
        _isSuggesting = false;
        _suggestError = widget.suggestManualPrompt;
      });
      return;
    }
    setState(() => _isSuggesting = false);
    widget.onSuggestNamed?.call(widget.entry, result.trim());
  }

  @override
  Widget build(BuildContext context) {
    final display = widget.entry.place.displayName.trim().isEmpty
        ? '(sem nome)'
        : widget.entry.place.displayName;
    final radius = widget.entry.place.radiusM;
    final count = widget.entry.count;
    final isAutoLoading = widget.isAutoLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: Key('places-named-${widget.entry.place.id}'),
          onTap: (widget.isAutoLoading || widget.onTap == null)
              ? null
              : () => widget.onTap!(widget.entry),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: AppSpacing.x2,
              horizontal: AppSpacing.x1,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        display,
                        style: AppText.bodyStrong.copyWith(
                          color: widget.colors.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: AppSpacing.x2,
                        children: [
                          _Chip(
                            label: '$count visitas',
                            icon: Icons.repeat,
                            colors: widget.colors,
                          ),
                          _Chip(
                            label: '${radius.toStringAsFixed(0)} m',
                            icon: Icons.radio_button_checked,
                            colors: widget.colors,
                          ),
                          if (isAutoLoading)
                            _Chip(
                              label: 'buscando nome…',
                              icon: Icons.hourglass_top,
                              colors: widget.colors,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (isAutoLoading)
                  SizedBox(
                    key: Key(
                      'places-named-auto-loading-${widget.entry.place.id}',
                    ),
                    width: 32,
                    height: 32,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (_shouldShowSuggest)
                  _SuggestButton(
                    key: Key('places-named-suggest-${widget.entry.place.id}'),
                    isLoading: _isSuggesting,
                    onPressed: _isSuggesting ? null : _handleSuggest,
                  )
                else if (widget.onTap != null)
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: widget.colors.inkSubtle,
                  )
                else
                  const SizedBox.shrink(),
                if (widget.onTap != null &&
                    (_shouldShowSuggest || isAutoLoading))
                  const SizedBox(width: AppSpacing.x1),
                if (widget.onTap != null &&
                    (_shouldShowSuggest || isAutoLoading))
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: widget.colors.inkSubtle,
                  ),
              ],
            ),
          ),
        ),
        if (_suggestError != null)
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.x1, top: 2),
            child: Text(
              _suggestError!,
              key: Key('places-named-suggest-error-${widget.entry.place.id}'),
              style: AppText.caption.copyWith(
                color: widget.colors.energy.warning,
              ),
            ),
          ),
      ],
    );
  }
}

class _UnnamedSection extends StatelessWidget {
  const _UnnamedSection({
    required this.candidates,
    required this.colors,
    this.onSelectCandidate,
    this.enableSuggest = false,
    this.onSuggest,
    this.onSuggestCandidate,
    this.suggestManualPrompt =
        'Não foi possível obter o endereço. Digite manualmente.',
    this.autoLoadingIds = const {},
  });

  final List<CandidatePlace> candidates;
  final AppThemeColors colors;
  final ValueChanged<CandidatePlace>? onSelectCandidate;
  final bool enableSuggest;
  final Future<String?> Function(double latitude, double longitude)? onSuggest;
  final void Function(CandidatePlace candidate, String suggestedName)?
  onSuggestCandidate;
  final String suggestManualPrompt;
  final Set<String> autoLoadingIds;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: const Key('places-unnamed-section'),
      title: PlacesBody.unnamedSectionTitle,
      child: Column(
        children: [
          for (final c in candidates)
            _CandidateRow(
              candidate: c,
              colors: colors,
              onTap: onSelectCandidate,
              enableSuggest: enableSuggest,
              onSuggest: onSuggest,
              onSuggestCandidate: onSuggestCandidate,
              suggestManualPrompt: suggestManualPrompt,
              isAutoLoading: autoLoadingIds.contains(c.id),
            ),
        ],
      ),
    );
  }
}

class _CandidateRow extends StatefulWidget {
  const _CandidateRow({
    required this.candidate,
    required this.colors,
    this.onTap,
    this.enableSuggest = false,
    this.onSuggest,
    this.onSuggestCandidate,
    this.suggestManualPrompt =
        'Não foi possível obter o endereço. Digite manualmente.',
    this.isAutoLoading = false,
  });

  final CandidatePlace candidate;
  final AppThemeColors colors;
  final ValueChanged<CandidatePlace>? onTap;
  final bool enableSuggest;
  final Future<String?> Function(double latitude, double longitude)? onSuggest;
  final void Function(CandidatePlace candidate, String suggestedName)?
  onSuggestCandidate;
  final String suggestManualPrompt;
  final bool isAutoLoading;

  @override
  State<_CandidateRow> createState() => _CandidateRowState();
}

class _CandidateRowState extends State<_CandidateRow> {
  bool _isSuggesting = false;
  String? _suggestError;

  bool get _shouldShowSuggest =>
      widget.enableSuggest &&
      widget.onSuggest != null &&
      widget.onSuggestCandidate != null;

  Future<void> _handleSuggest() async {
    final fetcher = widget.onSuggest;
    if (fetcher == null) return;
    setState(() {
      _isSuggesting = true;
      _suggestError = null;
    });
    String? result;
    try {
      result = await fetcher(
        widget.candidate.latitude,
        widget.candidate.longitude,
      );
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    if (result == null || result.trim().isEmpty) {
      setState(() {
        _isSuggesting = false;
        _suggestError = widget.suggestManualPrompt;
      });
      return;
    }
    setState(() => _isSuggesting = false);
    widget.onSuggestCandidate?.call(widget.candidate, result.trim());
  }

  @override
  Widget build(BuildContext context) {
    // Display as lat,lon rounded
    final title =
        '${widget.candidate.latitude.toStringAsFixed(4)}, ${widget.candidate.longitude.toStringAsFixed(4)}';
    final count = widget.candidate.count;
    // Candidate has no stored radius; show default
    const radius = kInsightPlaceRadiusM;
    final isAutoLoading = widget.isAutoLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: Key('places-candidate-${widget.candidate.id}'),
          onTap: (widget.isAutoLoading || widget.onTap == null)
              ? null
              : () => widget.onTap!(widget.candidate),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: AppSpacing.x2,
              horizontal: AppSpacing.x1,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppText.body.copyWith(
                          color: widget.colors.inkMuted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: AppSpacing.x2,
                        children: [
                          _Chip(
                            label: '$count visitas',
                            icon: Icons.repeat,
                            colors: widget.colors,
                          ),
                          _Chip(
                            label: '${radius.toStringAsFixed(0)} m',
                            icon: Icons.radio_button_checked,
                            colors: widget.colors,
                          ),
                          if (isAutoLoading)
                            _Chip(
                              label: 'buscando nome…',
                              icon: Icons.hourglass_top,
                              colors: widget.colors,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (isAutoLoading)
                  SizedBox(
                    key: Key(
                      'places-candidate-auto-loading-${widget.candidate.id}',
                    ),
                    width: 32,
                    height: 32,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else if (_shouldShowSuggest)
                  _SuggestButton(
                    key: Key('places-candidate-suggest-${widget.candidate.id}'),
                    isLoading: _isSuggesting,
                    onPressed: _isSuggesting ? null : _handleSuggest,
                  ),
                if (widget.onTap != null &&
                    (_shouldShowSuggest || isAutoLoading))
                  const SizedBox(width: AppSpacing.x1),
                if (widget.onTap != null)
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: widget.colors.inkSubtle,
                  ),
              ],
            ),
          ),
        ),
        if (_suggestError != null)
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.x1, top: 2),
            child: Text(
              _suggestError!,
              key: Key('places-candidate-suggest-error-${widget.candidate.id}'),
              style: AppText.caption.copyWith(
                color: widget.colors.energy.warning,
              ),
            ),
          ),
      ],
    );
  }
}

class _SuggestButton extends StatelessWidget {
  const _SuggestButton({required this.isLoading, this.onPressed, super.key});

  final bool isLoading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    if (isLoading) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: Padding(
          padding: EdgeInsets.all(8),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 16, color: colors.energy.focus),
            const SizedBox(width: 4),
            Text(
              'Sugerir',
              style: AppText.caption.copyWith(color: colors.energy.focus),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.icon, required this.colors});

  final String label;
  final IconData icon;
  final AppThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.control,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: colors.inkSubtle),
          const SizedBox(width: 4),
          Text(label, style: AppText.caption.copyWith(color: colors.inkMuted)),
        ],
      ),
    );
  }
}
