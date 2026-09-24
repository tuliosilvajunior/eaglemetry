import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/can_bridge_api.dart';
import '../../core/can_bridge_models.dart';
import '../../core/live_charge_can.dart';
import '../../core/telemetry_api.dart';
import '../../core/telemetry_scope.dart';
import '../../core/telemetry_format.dart';
import '../../design_system/design_system.dart';
import '../../l10n/app_localizations.dart';
import '../trips/live_trip_panels.dart';
import 'charging_event_card.dart';
import 'charging_session_detail_screen.dart';
import 'charging_session_display.dart';
import 'live_charge_detail_screen.dart';

/// The two reads this screen draws together.
typedef _ChargingPageData = ({
  SessionListPage sessions,
  TelemetrySettingsResult settings,
});

class ChargingSessionsScreen extends StatefulWidget {
  const ChargingSessionsScreen({super.key});

  @override
  State<ChargingSessionsScreen> createState() => _ChargingSessionsScreenState();
}

class _ChargingSessionsScreenState extends State<ChargingSessionsScreen> {
  /// A linha ao vivo mostra três números, não desenha curva. 1 Hz é o ritmo em
  /// que eles se leem; a tela cheia é que amostra a 16 Hz.
  static const Duration _liveSampleInterval = Duration(seconds: 1);

  static const Duration _canRetryInterval = Duration(seconds: 15);

  late final TelemetryApi _api = TelemetryScope.of(context);

  /// The screen's read. The list and the settings go together because they are
  /// drawn together: a cost column beside a session read a moment apart would
  /// be two answers presented as one.
  late final TelemetryQuery<_ChargingPageData> _charges = TelemetryQuery(
    read: _readPage,
    interval: const Duration(seconds: 20),
    debugLabel: 'ChargingSessionsScreen',
    // O carro avisa quando uma carga é escrita, encerrada, fundida ou
    // precificada. O tique de 20 s só corre com uma carga aberta, porque a
    // linha ao vivo lê SOC e hodômetro dos frames, e nenhum evento de sessão
    // anuncia esses.
    refreshOn: _api.sessionChanges().where((change) => change.charges),
  );
  Timer? _liveTimer;

  /// Só a linha ao vivo se redesenha a cada amostra. O `setState` que existia
  /// aqui reconstruía a lista de histórico inteira a cada frame do
  /// `EventChannel` — que publica a cada atualização de sinal, sem coalescência.
  final ValueNotifier<int> _liveTick = ValueNotifier<int>(0);

  CanBridge? _bridge;
  LiveChargeCanState? _can;
  bool _canConnecting = false;
  DateTime? _canAttemptAt;

  List<ChargeMergeCandidate> _mergeCandidates = const [];
  String? _mergingCandidateKey;

  /// A failure from the merge action, which is not the list's failure. It is
  /// cleared by the next successful read, because a list that has been re-read
  /// no longer carries the state the message described.
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _charges.addListener(_onChargesChanged);
    _charges.start();
    _startCollection();
  }

  @override
  void dispose() {
    _charges.removeListener(_onChargesChanged);
    _charges.dispose();
    _liveTimer?.cancel();
    _bridge?.dispose();
    _liveTick.dispose();
    super.dispose();
  }

  Future<void> _startCollection() async {
    try {
      await _api.startTelemetryCollection();
    } catch (_) {
      // A coleta pode já estar rodando pelo serviço em primeiro plano; a lista
      // não depende dela para desenhar o histórico.
    }
  }

  /// The currency the car's settings named, or the default until they arrive.
  String get _currency => _charges.value?.settings.chargeCostCurrency ?? 'BRL';

  List<SessionRecord> get _sessions =>
      _charges.value?.sessions.sessions ?? const <SessionRecord>[];

  void _onChargesChanged() {
    final state = _charges.state;
    if (!mounted) return;
    final read = !state.isLoading && state.error == null && state.value != null;
    if (read) _actionError = null;
    setState(() {});
    _syncLiveSampling();
    _charges.setPolling(_liveSession != null);
    // The candidates follow the list, so they are re-read when the list is —
    // not when it merely started reading, and not when the read failed and
    // left the previous list in place.
    if (read) unawaited(_loadMergeCandidates());
  }

  /// Sessão aberta, se houver. É ela que separa a linha ao vivo do histórico.
  SessionRecord? get _liveSession {
    for (final session in _sessions) {
      if (isLiveChargeStatus(session.status)) return session;
    }
    return null;
  }

  /// O barramento só é amostrado enquanto existe carga aberta: fora disso não há
  /// número ao vivo para mostrar, e manter uma sessão FFI viva com o carro
  /// parado é exatamente o consumo que esta tela tinha de sobra.
  void _syncLiveSampling() {
    final wanted = _liveSession != null;
    if (wanted && _liveTimer == null) {
      _connectCan();
      _liveTimer = Timer.periodic(_liveSampleInterval, (_) => _sampleCan());
    } else if (!wanted && _liveTimer != null) {
      _liveTimer?.cancel();
      _liveTimer = null;
      _bridge?.dispose();
      _bridge = null;
      _can = null;
    }
  }

  Future<void> _connectCan() async {
    if (_canConnecting) return;
    final last = _canAttemptAt;
    if (last != null && DateTime.now().difference(last) < _canRetryInterval) {
      return;
    }
    _canConnecting = true;
    _canAttemptAt = DateTime.now();
    try {
      final bridge = await CanBridge.connect(
        signals: LiveChargeCanNames.watchlist,
      );
      final entries = bridge?.entries ?? const <RoadcastSchemaEntry>[];
      if (!mounted) {
        bridge?.dispose();
        return;
      }
      _bridge?.dispose();
      _bridge = bridge;
      _can = bridge == null ? null : LiveChargeCanState(entries: entries);
      _canConnecting = false;
      _liveTick.value++;
    } on Object {
      _canConnecting = false;
      // A linha cai para os valores da sessão persistida; o erro do barramento
      // pertence à tela ao vivo, que tem espaço para explicá-lo.
    }
  }

  void _sampleCan() {
    final bridge = _bridge;
    final can = _can;
    if (bridge == null || can == null) {
      _connectCan();
      return;
    }
    if (!bridge.isAlive) {
      bridge.dispose();
      _bridge = null;
      _can = null;
      _liveTick.value++;
      _connectCan();
      return;
    }
    can.observe(bridge.sample(), DateTime.now().millisecondsSinceEpoch);
    _liveTick.value++;
  }

  /// Carrega a lista.
  ///
  /// Duas mudanças de ritmo:
  ///
  /// - a lista e as configurações vão **em paralelo**. Eram dois `await` em
  ///   sequência, e do outro lado da ponte havia uma única thread atendendo
  ///   todos os métodos, então a espera era a soma e não o máximo;
  /// - os candidatos a fusão saem do caminho crítico. São uma sugestão
  ///   secundária, e segurar a tela inteira até eles ficarem prontos era pagar
  ///   uma varredura de sessões antes de desenhar a primeira linha.
  Future<_ChargingPageData> _readPage() async {
    try {
      final (sessions, settings) = await (
        _api.listSessions(
          filter: const SessionFilter(kind: SessionKind.charge),
          page: const PageRequest(limit: 50),
        ),
        _api.getTelemetrySettings(),
      ).wait;
      return (sessions: sessions, settings: settings);
    } on ParallelWaitError<
      (SessionListPage?, TelemetrySettingsResult?),
      (AsyncError?, AsyncError?)
    > catch (error) {
      // `.wait` wraps both failures. The screen shows one line, so it reports
      // the first real cause rather than the wrapper, which names neither.
      throw error.errors.$1?.error ?? error.errors.$2?.error ?? error;
    }
  }

  /// Sugestão secundária, carregada depois da lista aparecer. Uma falha aqui
  /// nunca vira erro de tela: a lista está correta sem ela.
  Future<void> _loadMergeCandidates() async {
    try {
      final mergeResult = await _api.getChargeMergeCandidates(limit: 10);
      if (!mounted) return;
      setState(() => _mergeCandidates = mergeResult.candidates);
    } catch (_) {
      if (!mounted) return;
      setState(() => _mergeCandidates = const []);
    }
  }

  Future<void> _mergeCandidate(ChargeMergeCandidate candidate) async {
    final loc = AppLocalizations.of(context)!;
    final key = candidate.sessionIds.join('|');
    setState(() {
      _mergingCandidateKey = key;
      _actionError = null;
    });
    try {
      final result = await _api.mergeChargeSessions(
        sessionIds: candidate.sessionIds,
      );
      if (!mounted) return;
      if (!result.ok) {
        setState(() => _actionError = result.error ?? loc.chargeMergeError);
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(loc.chargeMergeSuccess)));
      await _charges.refresh();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError =
            '${error.code}: ${error.message ?? loc.chargeMergeError}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.toString());
    } finally {
      if (mounted) {
        setState(() => _mergingCandidateKey = null);
      }
    }
  }

  void _openLiveSession(SessionRecord session) {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LiveChargeDetailScreen(session: session),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final charges = _charges.state;
    final page = charges.value;
    final settings = page?.settings;
    final error = _actionError ?? charges.errorMessage;
    final loading = charges.isLoading;
    final live = _liveSession;
    // A sessão aberta é a linha ao vivo, no topo; repeti-la no histórico daria
    // duas linhas para a mesma carga, uma delas com números que ainda mudam.
    final historySessions = live == null
        ? _sessions
        : _sessions.where((s) => s.id != live.id).toList();
    final rows = _sessions.isEmpty && !loading && error == null
        ? _sampleRows(loc)
        : historySessions
              .map(
                (s) => ChargingSessionDisplay.fromSession(
                  s,
                  loc,
                  defaultCostPerKwh: settings?.defaultChargeCostPerKwh,
                ),
              )
              .toList();
    final usingSamples = _sessions.isEmpty && !loading && error == null;

    return ColoredBox(
      color: AutomotiveColors.background,
      child: Column(
        children: [
          ScreenHeaderBar(
            title: loc.appBarTitle,
            subtitle: loc.chargingSubtitle,
            trailing: [
              TechnicalChip(
                label: loc.chargingDbRows,
                value: (page?.sessions.totalCount ?? 0).toString(),
              ),
              const SizedBox(width: AutomotiveSpacing.x2),
              RefreshIconButton(
                tooltip: loc.chargingRefreshTooltip,
                loading: loading,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  unawaited(_charges.refresh(showLoading: true));
                },
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AutomotiveSpacing.marginScreen),
              children: [
                if (live != null) ...[
                  _LiveChargeRow(
                    session: live,
                    can: _can,
                    tick: _liveTick,
                    onOpen: () => _openLiveSession(live),
                  ),
                  const SizedBox(height: AutomotiveSpacing.x4),
                ],
                _HistoryToolbar(
                  rowCount: rows.length,
                  usingSamples: usingSamples,
                  error: error,
                ),
                if (_mergeCandidates.isNotEmpty) ...[
                  const SizedBox(height: AutomotiveSpacing.x2),
                  _ChargeMergePanel(
                    candidates: _mergeCandidates,
                    sessionsById: {
                      for (final session in _sessions) session.id: session,
                    },
                    mergingCandidateKey: _mergingCandidateKey,
                    onMerge: _mergeCandidate,
                  ),
                ],
                const SizedBox(height: AutomotiveSpacing.x2),
                if (loading)
                  const LoadingPanel()
                else if (error != null)
                  ErrorPanel(message: error)
                else
                  _ChargingSessionTable(rows: rows),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<ChargingSessionDisplay> _sampleRows(AppLocalizations loc) {
    final now = DateTime.now();
    return [
      ChargingSessionDisplay(
        id: 'sample-dc-001',
        status: 'SAMPLE COMPLETE',
        statusColor: AutomotiveColors.secondary,
        startedLabel: formatChargeEventDate(
          now.subtract(const Duration(days: 1)),
          loc,
        ),
        windowLabel: '08:14 - 08:56',
        durationLabel: '42m',
        plugLabel: 'DC FAST',
        socRange: '15.0% -> 82.0%',
        socDelta: '+67.0%',
        odometerRange: '12,884.2 km',
        odometerDelta: '+0.0 km',
        energyLabel: '54.8',
        powerLabel: '190.0 kW',
        costLabel: _currency == 'BRL' ? 'BRL 47.20' : '--',
        endReason: 'COMPLETED',
        updatedLabel: 'sample row',
        session: null,
        isSample: true,
      ),
      ChargingSessionDisplay(
        id: 'sample-ac-002',
        status: 'SAMPLE ENDED',
        statusColor: AutomotiveColors.onSurfaceVariant,
        startedLabel: formatChargeEventDate(
          now.subtract(const Duration(days: 3)),
          loc,
        ),
        windowLabel: '22:04 - 23:15',
        durationLabel: '1h 11m',
        plugLabel: 'AC',
        socRange: '45.0% -> 54.0%',
        socDelta: '+9.0%',
        odometerRange: '12,741.8 km',
        odometerDelta: '+0.0 km',
        energyLabel: '6.4',
        powerLabel: '7.4 kW',
        costLabel: _currency == 'BRL' ? 'BRL 8.90' : '--',
        endReason: 'PLUG_DISCONNECTED',
        updatedLabel: 'sample row',
        session: null,
        isSample: true,
      ),
      ChargingSessionDisplay(
        id: 'sample-wait-003',
        status: 'SAMPLE CONNECTED',
        statusColor: AutomotiveColors.warning,
        startedLabel: formatChargeEventDate(
          now.subtract(const Duration(days: 5)),
          loc,
        ),
        windowLabel: '18:32 - --:--',
        durationLabel: 'active',
        plugLabel: 'INTEGRATION',
        socRange: '61.0% -> --',
        socDelta: '--',
        odometerRange: '12,603.5 km',
        odometerDelta: '--',
        energyLabel: '--',
        powerLabel: '--',
        costLabel: '--',
        endReason: 'WAITING_FOR_POWER',
        updatedLabel: 'sample row',
        session: null,
        isSample: true,
      ),
    ];
  }
}

/// Faixa da sessão aberta, acima do histórico.
///
/// Três números e um atalho. Ela não desenha curva de propósito: a lista é uma
/// lista, e quem quer a forma da carga abre a tela ao vivo — que é onde a
/// amostragem rápida e os gráficos vivem.
class _LiveChargeRow extends StatelessWidget {
  const _LiveChargeRow({
    required this.session,
    required this.can,
    required this.tick,
    required this.onOpen,
  });

  final SessionRecord session;
  final LiveChargeCanState? can;
  final ValueNotifier<int> tick;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final startedAt = dateTimeFromMillis(
      session.chargeStartedAtUtcMillis ?? session.startedAtUtcMillis,
    );
    final elapsed =
        durationFromMillis(sessionReadingDurationMillis(session)) ??
        boundedDurationBetween(
          startedAt,
          null,
          maximum: const Duration(days: 31),
        );
    final charging = session.status.toUpperCase() == 'CHARGING';

    return TechnicalPanel(
      borderColor: AutomotiveColors.secondary.withValues(alpha: 0.65),
      // A lista vive dentro do shell, sem Scaffold próprio; o InkWell precisa de
      // um Material acima dele para desenhar o toque.
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onOpen,
          borderRadius: AutomotiveRadii.mdRadius,
          child: Padding(
            padding: const EdgeInsets.all(AutomotiveSpacing.x1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    LivePulse(label: loc.liveChargeRowTitle, active: charging),
                    const SizedBox(width: AutomotiveSpacing.x2),
                    Expanded(
                      child: Text(
                        '${chargePlugLabel(session.plugType, loc)} · '
                        '${chargeFormatElapsed(elapsed, active: true)}',
                        overflow: TextOverflow.ellipsis,
                        style: AutomotiveTextStyles.unitLabel.copyWith(
                          color: AutomotiveColors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    TechnicalButton(
                      icon: Icons.open_in_full,
                      label: loc.liveChargeOpen,
                      onPressed: onOpen,
                      accentIcon: true,
                    ),
                  ],
                ),
                const SizedBox(height: AutomotiveSpacing.x2),
                // Só esta parte se redesenha a 1 Hz.
                ValueListenableBuilder<int>(
                  valueListenable: tick,
                  builder: (context, _, _) => Wrap(
                    spacing: AutomotiveSpacing.x4,
                    runSpacing: AutomotiveSpacing.x2,
                    children: [
                      SizedBox(
                        width: 170,
                        child: MetricReadout(
                          label: loc.liveChargeInputPower,
                          value: _kw(_inputPowerKw, loc),
                          accent: true,
                        ),
                      ),
                      SizedBox(
                        width: 150,
                        child: MetricReadout(
                          label: loc.liveTripSoc,
                          value: can?.socPercent == null
                              ? socRangeLabel(
                                  session.startSoc.displayValue,
                                  session.endSoc.displayValue,
                                )
                              : '${can!.socPercent!.toStringAsFixed(1)} %',
                        ),
                      ),
                      SizedBox(
                        width: 170,
                        child: MetricReadout(
                          label: loc.liveChargePackCurrent,
                          value: can?.packCurrentA == null
                              ? '--'
                              : '${can!.packCurrentA!.toStringAsFixed(1)} '
                                    '${loc.chartCurrentUnit}',
                        ),
                      ),
                      SizedBox(
                        width: 160,
                        child: MetricReadout(
                          label: loc.liveChargeObcEfficiency,
                          value: can?.obcEfficiency == null
                              ? '--'
                              : '${(can!.obcEfficiency! * 100).toStringAsFixed(0)} %',
                        ),
                      ),
                      SizedBox(
                        width: 170,
                        child: MetricReadout(
                          label: loc.liveChargeEnergyAdded,
                          value: energyLabel(
                            sessionReadingDeliveredKwh(session).displayValue,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _kw(double? value, AppLocalizations loc) => value == null
      ? '--'
      : '${value.toStringAsFixed(2)} ${loc.chartPowerUnit}';

  double? get _inputPowerKw {
    final readings = can?.inputReadings(
      isDc: isDcChargePlugType(session.plugType),
    );
    return readings?.powerKw;
  }
}

class _HistoryToolbar extends StatelessWidget {
  const _HistoryToolbar({
    required this.rowCount,
    required this.usingSamples,
    required this.error,
  });

  final int rowCount;
  final bool usingSamples;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final detail = error != null
        ? loc.bridgeError
        : usingSamples
        ? loc.noDbRows
        : loc.roomChargeSessions;
    return Row(
      children: [
        Flexible(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  loc.historySectionTitle,
                  overflow: TextOverflow.ellipsis,
                  style: AutomotiveTextStyles.labelCaps.copyWith(
                    color: AutomotiveColors.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: AutomotiveSpacing.x2),
              Container(
                width: 1,
                height: 18,
                color: AutomotiveColors.outlineVariant.withValues(alpha: 0.6),
              ),
              const SizedBox(width: AutomotiveSpacing.x2),
              Flexible(
                child: Text(
                  detail,
                  overflow: TextOverflow.ellipsis,
                  style: AutomotiveTextStyles.unitLabel.copyWith(
                    color: AutomotiveColors.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AutomotiveSpacing.x2),
        Text(
          '$rowCount ${loc.historyRows}',
          style: AutomotiveTextStyles.unitLabel.copyWith(
            color: AutomotiveColors.secondary,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _ChargeMergePanel extends StatelessWidget {
  const _ChargeMergePanel({
    required this.candidates,
    required this.sessionsById,
    required this.mergingCandidateKey,
    required this.onMerge,
  });

  final List<ChargeMergeCandidate> candidates;

  /// The rows the list already read, by id.
  ///
  /// The candidate names the sessions it would join; the record of each one
  /// comes from the same list this panel sits under, so the panel does not
  /// hold a second copy of a session that the list is already showing.
  final Map<String, SessionRecord> sessionsById;
  final String? mergingCandidateKey;
  final ValueChanged<ChargeMergeCandidate> onMerge;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return TechnicalPanel(
      borderColor: AutomotiveColors.warning.withValues(alpha: 0.75),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.call_merge, color: AutomotiveColors.warning, size: 20),
              const SizedBox(width: AutomotiveSpacing.x1),
              Expanded(
                child: Text(
                  loc.chargeMergeTitle,
                  overflow: TextOverflow.ellipsis,
                  style: AutomotiveTextStyles.labelCaps.copyWith(
                    color: AutomotiveColors.warning,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AutomotiveSpacing.x1),
          Text(
            loc.chargeMergeDescription,
            style: AutomotiveTextStyles.bodyMd.copyWith(
              color: AutomotiveColors.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: AutomotiveSpacing.x2),
          for (final candidate in candidates) ...[
            _ChargeMergeCandidateCard(
              candidate: candidate,
              sessionsById: sessionsById,
              merging: mergingCandidateKey == candidate.sessionIds.join('|'),
              onMerge: () => onMerge(candidate),
            ),
            if (candidate != candidates.last)
              const SizedBox(height: AutomotiveSpacing.x2),
          ],
        ],
      ),
    );
  }
}

class _ChargeMergeCandidateCard extends StatelessWidget {
  const _ChargeMergeCandidateCard({
    required this.candidate,
    required this.sessionsById,
    required this.merging,
    required this.onMerge,
  });

  final ChargeMergeCandidate candidate;

  /// The rows the list already read, by id. See [_ChargeMergePanel].
  final Map<String, SessionRecord> sessionsById;
  final bool merging;
  final VoidCallback onMerge;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AutomotiveColors.surfaceContainerLow,
        border: Border.all(color: AutomotiveColors.technicalBorder),
        borderRadius: AutomotiveRadii.mdRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AutomotiveSpacing.x2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: AutomotiveSpacing.x3,
              runSpacing: AutomotiveSpacing.x2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                MetricReadout(
                  label: loc.chargeMergeSessionsLabel,
                  value: candidate.sessionIds.length.toString(),
                  accent: true,
                ),
                MetricReadout(
                  label: loc.chargeMergeSocLabel,
                  value: socRangeLabel(candidate.startSoc, candidate.endSoc),
                ),
                MetricReadout(
                  label: loc.chargeMergeFramesLabel,
                  value: candidate.totalFrames.toString(),
                ),
                MetricReadout(
                  label: loc.chargeMergeGapLabel,
                  value: _formatCandidateGap(candidate),
                ),
                TechnicalButton(
                  icon: Icons.check,
                  label: merging
                      ? loc.chargeMergeMerging
                      : loc.chargeMergeConfirm,
                  onPressed: merging ? null : onMerge,
                  accentIcon: true,
                ),
              ],
            ),
            const SizedBox(height: AutomotiveSpacing.x2),
            for (final id in candidate.sessionIds)
              if (sessionsById[id] case final session?)
                _MergeSessionLine(session: session),
            for (final gap in candidate.breaks) _MergeBreakLine(gap: gap),
          ],
        ),
      ),
    );
  }
}

class _MergeSessionLine extends StatelessWidget {
  const _MergeSessionLine({required this.session});

  final SessionRecord session;

  @override
  Widget build(BuildContext context) {
    final started = dateTimeFromMillis(
      session.chargeStartedAtUtcMillis ?? session.startedAtUtcMillis,
    );
    final ended = dateTimeFromMillis(
      session.plugDisconnectedAtUtcMillis ?? session.chargeEndedAtUtcMillis,
    );
    final display = ChargingSessionDisplay.fromSession(
      session,
      AppLocalizations.of(context)!,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: AutomotiveSpacing.x1),
      child: Row(
        children: [
          Container(width: 6, height: 28, color: display.statusColor),
          const SizedBox(width: AutomotiveSpacing.x1),
          Expanded(
            flex: 2,
            child: Text(
              display.shortId,
              overflow: TextOverflow.ellipsis,
              style: AutomotiveTextStyles.unitLabel.copyWith(fontSize: 12),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              '${formatWindow(started, ended)} (${display.durationLabel})',
              overflow: TextOverflow.ellipsis,
              style: AutomotiveTextStyles.bodyMd.copyWith(fontSize: 13),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              display.socRange,
              overflow: TextOverflow.ellipsis,
              style: AutomotiveTextStyles.unitLabel.copyWith(fontSize: 12),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              session.endReason ?? display.status,
              overflow: TextOverflow.ellipsis,
              style: AutomotiveTextStyles.bodyMd.copyWith(
                color: AutomotiveColors.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MergeBreakLine extends StatelessWidget {
  const _MergeBreakLine({required this.gap});

  final ChargeMergeBreak gap;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: AutomotiveSpacing.x0_5),
      child: Row(
        children: [
          Icon(Icons.link, size: 16, color: AutomotiveColors.warning),
          const SizedBox(width: AutomotiveSpacing.x1),
          Expanded(
            child: Text(
              '${loc.chargeMergeBreakLabel}: ${_shortId(gap.previousSessionId)} -> '
              '${_shortId(gap.nextSessionId)} / ${_formatMillisShort(gap.gapMillis)} / '
              '${_formatSignedValue(gap.socDelta, suffix: '%')} SOC',
              overflow: TextOverflow.ellipsis,
              style: AutomotiveTextStyles.bodyMd.copyWith(
                color: AutomotiveColors.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChargingSessionTable extends StatelessWidget {
  const _ChargingSessionTable({required this.rows});

  final List<ChargingSessionDisplay> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (int i = 0; i < rows.length; i++) ...[
          ChargingEventCard(
            row: rows[i],
            onTap: () {
              HapticFeedback.selectionClick();
              final session = rows[i].session;
              if (session == null) return;
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChargeSessionDetailScreen(session: session),
                ),
              );
            },
          ),
          if (i != rows.length - 1)
            const SizedBox(height: AutomotiveSpacing.x2),
        ],
      ],
    );
  }
}

String _formatCandidateGap(ChargeMergeCandidate candidate) {
  if (candidate.breaks.isEmpty) return '--';
  final total = candidate.breaks.fold<int>(
    0,
    (sum, gap) => sum + gap.gapMillis,
  );
  return _formatMillisShort(total);
}

String _formatMillisShort(int millis) {
  final seconds = (millis / 1000).round();
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  if (minutes < 60) return '${minutes}m ${remainingSeconds}s';
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return '${hours}h ${remainingMinutes}m';
}

String _formatSignedValue(double? value, {String suffix = ''}) {
  if (value == null) return '--';
  final sign = value >= 0 ? '+' : '';
  return '$sign${value.toStringAsFixed(1)}$suffix';
}

String _shortId(String id) {
  if (id.length <= 12) return id;
  return '${id.substring(0, 8)}...${id.substring(id.length - 4)}';
}
