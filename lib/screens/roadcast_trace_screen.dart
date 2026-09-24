import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/can_activity.dart';
import '../core/can_bridge_api.dart';
import '../design_system/design_system.dart';
import '../l10n/app_localizations.dart';

/// Tela de atividade CAN ao vivo.
///
/// Reads Roadcast's native RAM cache through `dart:ffi`, with no platform channel
/// in the hot path. Socket I/O and resynchronization remain on the native reader
/// thread rather than the Flutter render thread.
///
/// O foco é **o que muda**. A maioria dos 815 sinais fica parada ou zerada o tempo
/// todo, então por padrão a lista só mostra quem já mudou alguma vez, ordenada por
/// quem mudou mais recentemente — a pergunta prática sendo "o que reagiu ao que eu
/// acabei de fazer?". Qualquer sinal ruidoso pode ser silenciado, e a lista de
/// silenciados sobrevive ao fechamento do app.
class RoadcastTraceScreen extends StatefulWidget {
  const RoadcastTraceScreen({super.key});

  @override
  State<RoadcastTraceScreen> createState() => _RoadcastTraceScreenState();
}

class _RoadcastTraceScreenState extends State<RoadcastTraceScreen> {
  static const String _mutedPrefsKey = 'canLive.mutedSignals';

  /// A 10 Hz UI sample rate is enough for gauges and sparklines while Roadcast
  /// maintains its cache at the daemon acquisition rate.
  static const Duration _sampleInterval = Duration(milliseconds: 100);
  static const Duration _reconnectInterval = Duration(seconds: 2);

  CanBridge? _bridge;
  CanActivityTracker? _tracker;
  Timer? _timer;
  String? _error;
  bool _connecting = true;
  bool _reconnecting = false;
  DateTime? _lastReconnectAttempt;

  final TextEditingController _search = TextEditingController();
  bool _onlyChanging = true;
  bool _showMuted = false;
  bool _validOnly = false;
  CanActivitySort _sort = CanActivitySort.recency;
  String? _selectedName;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _bridge?.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final previousBridge = _bridge;
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      // Observa a schema inteira negociada: descobrir o que mexe exige olhar
      // tudo, e a leitura em lote é uma travessia FFI só.
      final bridge = await CanBridge.connect();
      if (!mounted) {
        bridge?.dispose();
        return;
      }
      if (bridge == null) {
        setState(() {
          _connecting = false;
          _bridge = null;
        });
        previousBridge?.dispose();
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_mutedPrefsKey);

      if (!mounted) {
        bridge.dispose();
        return;
      }
      final tracker = CanActivityTracker(
        entries: bridge.entries,
        muted: stored?.toSet(),
      );
      // Primeira execução: silencia contadores e checksums, que mudam por
      // construção e ocupariam o topo do ranking para sempre. Depois disso vale o
      // que estiver salvo — inclusive uma lista vazia, se o usuário reativou tudo.
      if (stored == null) {
        for (final name in tracker.noisySignalNames()) {
          tracker.mute(name);
        }
        unawaited(prefs.setStringList(_mutedPrefsKey, tracker.muted.toList()));
      }
      setState(() {
        _bridge = bridge;
        _tracker = tracker;
        _connecting = false;
      });
      previousBridge?.dispose();
      _timer?.cancel();
      _timer = Timer.periodic(_sampleInterval, (_) => _sample());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = error.toString();
      });
    }
  }

  void _sample() {
    final bridge = _bridge;
    final tracker = _tracker;
    if (bridge == null || tracker == null) return;
    if (!bridge.isAlive) {
      unawaited(_reconnectIfDue());
      setState(() {});
      return;
    }
    tracker.observe(bridge.sample(), DateTime.now().millisecondsSinceEpoch);
    setState(() {});
  }

  Future<void> _reconnectIfDue() async {
    if (_reconnecting || !mounted) return;
    final now = DateTime.now();
    final lastAttempt = _lastReconnectAttempt;
    if (lastAttempt != null &&
        now.difference(lastAttempt) < _reconnectInterval) {
      return;
    }

    _reconnecting = true;
    _lastReconnectAttempt = now;
    try {
      final replacement = await CanBridge.connect();
      if (!mounted) {
        replacement?.dispose();
        return;
      }
      if (replacement == null) return;

      final previous = _bridge;
      final replacementTracker = CanActivityTracker(
        entries: replacement.entries,
        muted: _tracker?.muted,
      );
      setState(() {
        _bridge = replacement;
        _tracker = replacementTracker;
        _error = null;
      });
      previous?.dispose();
    } on Object {
      // The stale banner remains visible while the bounded retry loop continues.
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> _persistMuted() async {
    final tracker = _tracker;
    if (tracker == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_mutedPrefsKey, tracker.muted.toList());
  }

  void _toggleMute(CanSignalActivity signal) {
    final tracker = _tracker;
    if (tracker == null) return;
    setState(() {
      if (tracker.isMuted(signal.name)) {
        tracker.unmute(signal.name);
      } else {
        tracker.mute(signal.name);
        if (_selectedName == signal.name) _selectedName = null;
      }
    });
    unawaited(_persistMuted());
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final tracker = _tracker;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ScreenHeaderBar(
          title: loc.roadcastTraceTitle,
          subtitle: loc.roadcastTraceSubtitle,
          trailing: [
            if (tracker != null) ...[
              TechnicalChip(
                label: loc.canLiveMetricActive,
                value: '${tracker.activeCount(nowMs)}',
              ),
              const SizedBox(width: AutomotiveSpacing.x1),
              TechnicalChip(
                label: loc.roadcastTraceMetricChanged,
                value: '${tracker.changedCount}',
              ),
              const SizedBox(width: AutomotiveSpacing.x1),
              TechnicalChip(
                label: loc.canLiveMutedList,
                value: '${tracker.mutedCount}',
              ),
              const SizedBox(width: AutomotiveSpacing.x2),
            ],
            RefreshIconButton(onPressed: _connect),
          ],
        ),
        Expanded(child: _body(loc, tracker, nowMs)),
      ],
    );
  }

  Widget _body(AppLocalizations loc, CanActivityTracker? tracker, int nowMs) {
    if (_connecting) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(AutomotiveSpacing.marginScreen),
        child: Center(
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: AutomotiveTextStyles.bodyMd.copyWith(
              color: AutomotiveColors.error,
            ),
          ),
        ),
      );
    }
    final bridge = _bridge;
    if (tracker == null || bridge == null) {
      return _message(loc.canLiveWaiting);
    }

    final visible = tracker.ranked(
      query: _search.text,
      onlyChanging: _onlyChanging,
      showMuted: _showMuted,
      sort: _sort,
      validOnly: _validOnly,
    );
    final selected = _selectedName == null
        ? tracker.mostActive()
        : tracker.byName(_selectedName!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!bridge.isAlive)
          Container(
            width: double.infinity,
            color: AutomotiveColors.error.withValues(alpha: 0.15),
            padding: const EdgeInsets.symmetric(
              horizontal: AutomotiveSpacing.marginScreen,
              vertical: AutomotiveSpacing.x1,
            ),
            child: Text(
              loc.canLiveStale,
              style: AutomotiveTextStyles.labelCaps.copyWith(
                color: AutomotiveColors.error,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AutomotiveSpacing.marginScreen,
            AutomotiveSpacing.x2,
            AutomotiveSpacing.marginScreen,
            AutomotiveSpacing.x1,
          ),
          child: _Gauge(signal: selected, loc: loc, nowMs: nowMs),
        ),
        _controls(loc),
        Expanded(
          child: visible.isEmpty
              ? _message(loc.roadcastTraceEmpty)
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AutomotiveSpacing.marginScreen,
                  ),
                  itemCount: visible.length,
                  itemExtent: 44,
                  itemBuilder: (context, i) {
                    final signal = visible[i];
                    return _SignalRow(
                      signal: signal,
                      nowMs: nowMs,
                      selected: signal.name == selected?.name,
                      muted: tracker.isMuted(signal.name),
                      loc: loc,
                      onTap: () => setState(() => _selectedName = signal.name),
                      onMute: () => _toggleMute(signal),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _controls(AppLocalizations loc) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AutomotiveSpacing.marginScreen,
        vertical: AutomotiveSpacing.x1,
      ),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                style: AutomotiveTextStyles.bodyMd,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: loc.roadcastTraceSearchHint,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          ),
          const SizedBox(width: AutomotiveSpacing.x2),
          _toggle(
            label: loc.roadcastTraceChangedOnly,
            value: _onlyChanging,
            onTap: () => setState(() => _onlyChanging = !_onlyChanging),
          ),
          const SizedBox(width: AutomotiveSpacing.x1),
          _toggle(
            label: loc.roadcastTraceValidOnly,
            value: _validOnly,
            onTap: () => setState(() => _validOnly = !_validOnly),
          ),
          const SizedBox(width: AutomotiveSpacing.x1),
          _toggle(
            label: loc.canLiveMutedList,
            value: _showMuted,
            onTap: () => setState(() => _showMuted = !_showMuted),
          ),
          const SizedBox(width: AutomotiveSpacing.x2),
          _sortButton(CanActivitySort.recency, loc.canLiveSortRecency),
          _sortButton(CanActivitySort.rate, loc.canLiveSortRate),
          _sortButton(CanActivitySort.name, loc.canLiveSortName),
          const SizedBox(width: AutomotiveSpacing.x2),
          TechnicalButton(
            icon: Icons.restart_alt,
            label: loc.roadcastTraceClear,
            onPressed: () => setState(() => _tracker?.resetAll()),
          ),
        ],
      ),
    );
  }

  Widget _sortButton(CanActivitySort sort, String label) {
    return Padding(
      padding: const EdgeInsets.only(right: AutomotiveSpacing.x0_5),
      child: _toggle(
        label: label,
        value: _sort == sort,
        onTap: () => setState(() => _sort = sort),
      ),
    );
  }

  Widget _toggle({
    required String label,
    required bool value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AutomotiveSpacing.x1_5,
          vertical: AutomotiveSpacing.x1,
        ),
        decoration: BoxDecoration(
          color: value
              ? AutomotiveColors.secondaryContainer
              : AutomotiveColors.surfaceContainer,
          border: Border.all(
            color: value
                ? AutomotiveColors.secondary
                : AutomotiveColors.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: AutomotiveTextStyles.labelCaps.copyWith(
            color: value
                ? AutomotiveColors.onSecondaryContainer
                : AutomotiveColors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _message(String text) => Center(
    child: Text(
      text,
      style: AutomotiveTextStyles.bodyMd.copyWith(
        color: AutomotiveColors.onSurfaceVariant,
      ),
    ),
  );
}

/// Gauge grande do sinal selecionado: valor, unidade, taxa de mudança e a forma
/// recente do sinal.
class _Gauge extends StatelessWidget {
  const _Gauge({required this.signal, required this.loc, required this.nowMs});

  final CanSignalActivity? signal;
  final AppLocalizations loc;
  final int nowMs;

  @override
  Widget build(BuildContext context) {
    final active = signal;
    return TechnicalPanel(
      child: SizedBox(
        height: 148,
        child: active == null
            ? Center(
                child: Text(
                  loc.roadcastTraceSelectSignal,
                  style: AutomotiveTextStyles.bodyMd.copyWith(
                    color: AutomotiveColors.onSurfaceVariant,
                  ),
                ),
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          active.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AutomotiveTextStyles.labelCaps.copyWith(
                            color: AutomotiveColors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: AutomotiveSpacing.x0_5),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                _formatValue(active),
                                style: AutomotiveTextStyles.metricDisplay
                                    .copyWith(
                                      color: active.valid
                                          ? AutomotiveColors.onSurface
                                          : AutomotiveColors.outline,
                                    ),
                              ),
                              if (active.unit.isNotEmpty) ...[
                                const SizedBox(width: AutomotiveSpacing.x1),
                                Text(
                                  active.unit,
                                  style: AutomotiveTextStyles.unitLabel
                                      .copyWith(
                                        color:
                                            AutomotiveColors.onSurfaceVariant,
                                      ),
                                ),
                              ],
                              const SizedBox(width: AutomotiveSpacing.x2),
                              Text(
                                '${loc.roadcastTraceRaw} ${active.raw}',
                                style: AutomotiveTextStyles.unitLabel.copyWith(
                                  color: AutomotiveColors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AutomotiveSpacing.x1),
                        Wrap(
                          spacing: AutomotiveSpacing.x1,
                          children: [
                            TechnicalChip(
                              label: loc.roadcastTraceHeaderId,
                              value:
                                  '0x${active.canId.toRadixString(16).toUpperCase()}',
                            ),
                            TechnicalChip(
                              label: loc.canLiveMetricRate,
                              value: active.changesPerSecond.toStringAsFixed(1),
                            ),
                            TechnicalChip(
                              label: loc.roadcastTraceHeaderChanges,
                              value: '${active.changeCount}',
                            ),
                            TechnicalChip(
                              label: loc.roadcastTraceHeaderLast,
                              value: _formatAge(active, nowMs, loc),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AutomotiveSpacing.x2),
                  Expanded(
                    flex: 6,
                    child: Sparkline(
                      values: active.history,
                      color: AutomotiveColors.secondary,
                      emptyMessage: loc.roadcastTraceChartEmpty,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _SignalRow extends StatelessWidget {
  const _SignalRow({
    required this.signal,
    required this.nowMs,
    required this.selected,
    required this.muted,
    required this.loc,
    required this.onTap,
    required this.onMute,
  });

  final CanSignalActivity signal;
  final int nowMs;
  final bool selected;
  final bool muted;
  final AppLocalizations loc;
  final VoidCallback onTap;
  final VoidCallback onMute;

  @override
  Widget build(BuildContext context) {
    // Quanto mais recente a mudança, mais forte o realce: a linha "pisca" e o olho
    // acha sozinho o sinal que acabou de reagir.
    final sinceChange = nowMs - signal.lastChangeAtMs;
    final heat = signal.everChanged
        ? (1 - (sinceChange / 1500)).clamp(0.0, 1.0)
        : 0.0;

    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Color.lerp(
            selected
                ? AutomotiveColors.surfaceContainerHigh
                : Colors.transparent,
            AutomotiveColors.secondary.withValues(alpha: 0.22),
            heat,
          ),
          border: Border(
            bottom: BorderSide(color: AutomotiveColors.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: AutomotiveSpacing.x1),
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(
                '0x${signal.canId.toRadixString(16).toUpperCase()}',
                style: AutomotiveTextStyles.bodyMd.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              flex: 5,
              child: Text(
                signal.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AutomotiveTextStyles.bodyMd.copyWith(
                  color: muted
                      ? AutomotiveColors.outline
                      : AutomotiveColors.onSurface,
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  '${_formatValue(signal)}  ${loc.roadcastTraceRaw} ${signal.raw}',
                  textAlign: TextAlign.right,
                  style: AutomotiveTextStyles.bodyMd.copyWith(
                    color: signal.valid
                        ? AutomotiveColors.onSurface
                        : AutomotiveColors.outline,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 44,
              child: Padding(
                padding: const EdgeInsets.only(left: AutomotiveSpacing.x0_5),
                child: Text(
                  signal.unit,
                  style: AutomotiveTextStyles.bodyMd.copyWith(
                    color: AutomotiveColors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 72,
              child: Text(
                signal.changesPerSecond > 0
                    ? '${signal.changesPerSecond.toStringAsFixed(1)}/s'
                    : '--',
                textAlign: TextAlign.right,
                style: AutomotiveTextStyles.bodyMd.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                ),
              ),
            ),
            SizedBox(
              width: 96,
              child: Text(
                _formatAge(signal, nowMs, loc),
                textAlign: TextAlign.right,
                style: AutomotiveTextStyles.bodyMd.copyWith(
                  color: AutomotiveColors.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              iconSize: 18,
              tooltip: muted ? loc.canLiveUnmute : loc.canLiveMute,
              icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
              color: muted
                  ? AutomotiveColors.error
                  : AutomotiveColors.onSurfaceVariant,
              onPressed: onMute,
            ),
          ],
        ),
      ),
    );
  }
}

String _formatValue(CanSignalActivity signal) {
  if (!signal.valid) return '--';
  // Sem escala calibrada o "valor físico" é o próprio cru; mostrar decimais aí
  // sugeriria uma precisão que não existe.
  if (!signal.calibrated && signal.value == signal.raw.toDouble()) {
    return signal.raw.toString();
  }
  final magnitude = signal.value.abs();
  if (magnitude >= 100) return signal.value.toStringAsFixed(0);
  if (magnitude >= 10) return signal.value.toStringAsFixed(1);
  return signal.value.toStringAsFixed(2);
}

String _formatAge(CanSignalActivity signal, int nowMs, AppLocalizations loc) {
  final age = signal.ageSince(nowMs);
  if (age == null) return loc.canLiveNeverChanged;
  if (age.inMilliseconds < 1000) return '${age.inMilliseconds} ms';
  if (age.inSeconds < 60) return '${age.inSeconds} s';
  return '${age.inMinutes} min';
}
