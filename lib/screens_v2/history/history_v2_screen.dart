import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/telemetry_api.dart';
import '../../core/telemetry_scope.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import '../charge_cost_editor.dart';
import 'battery_history_pane.dart';
import 'history_constants.dart';
import 'history_detail_fullscreen.dart';
import 'history_detail_page.dart';
import 'history_detail_summary.dart';
import 'history_list.dart';

/// What the history card is showing.
///
/// Two entries today. The rail exists at one entry as readily as at four, and
/// it is what makes a third kind of record — a month, a location, a fault log —
/// an entry rather than another tab.
enum HistoryCategory { trips, charges, battery }

/// Past drives and past charges, with the selected one on the stage.
///
/// Two slots. The left one is the same master-detail component the settings
/// menu floats (`CategoryMenu`): a rail of what can be looked back at, and the
/// records of the selected one. The right one is whichever record is open, and
/// it is the stage's expandable slot — selecting a session takes it fullscreen,
/// which shoves the rail and the list off the left edge, and dragging it back
/// down returns them.
///
/// The stage is owned here rather than by the shell, unlike CarPlay's: nothing
/// outside this screen has to move with it. That is deliberate — the tab row
/// stays put while the card takes over the body, because a reader looking at
/// one drive has not left the journey.
class HistoryV2Screen extends StatefulWidget {
  const HistoryV2Screen({required this.title, this.telemetryApi, super.key});

  final String title;

  /// Seam for tests. Production passes nothing and gets the shared api through
  /// [TelemetryScope].
  final TelemetryApi? telemetryApi;

  @override
  State<HistoryV2Screen> createState() => _HistoryV2ScreenState();
}

class _HistoryV2ScreenState extends State<HistoryV2Screen>
    with TickerProviderStateMixin {
  late final TelemetryApi _api =
      widget.telemetryApi ?? TelemetryScope.of(context);

  late final CardStageController _stage = CardStageController(vsync: this);

  HistoryCategory _category = HistoryCategory.trips;

  /// One selection per category, so switching the rail back and forth does not
  /// forget which drive was open.
  /// The id, not the row: the row a list handed over is a snapshot, and the
  /// price on a charge can be written while the card is open. The detail read
  /// asks the store for the session again, so the card cannot hold a stale
  /// copy of the record it is drawing.
  String? _selectedTripId;
  String? _selectedChargeId;
  BatteryCycleSummary? _selectedCycle;

  /// The open session's detail.
  ///
  /// Held here, above the stage, and not inside the detail card: a slot that
  /// varies by size is re-keyed on every size change, so a query living in it
  /// would be disposed and restarted at the exact moment the card goes
  /// fullscreen — the read the reader is waiting for, thrown away by the
  /// gesture that asked for it.
  late final TelemetryQuery<HistoryDetailPage?> _detail = TelemetryQuery(
    read: _readDetail,
    interval: historyFallbackInterval,
    // Pricing a charge is a session write, and the price is on this card.
    refreshOn: _api.sessionChanges().where((change) => change.charges),
    debugLabel: 'HistoryV2Screen.detail',
  );

  /// The charge-cost defaults, for a charge that was never priced.
  ///
  /// Read once and kept on the slow fallback tick, because the only thing that
  /// moves it is someone opening Settings.
  late final TelemetryQuery<TelemetrySettingsResult> _settings = TelemetryQuery(
    read: _api.getTelemetrySettings,
    interval: historyFallbackInterval,
    debugLabel: 'HistoryV2Screen.settings',
  );

  /// True while a price write is in flight. The keypad stays shut until the
  /// collector has answered, so two prices cannot race for one session.
  bool _savingChargeCost = false;

  @override
  void initState() {
    super.initState();
    _detail.addListener(_onDetailChanged);
    _detail.start();
    _settings.start();
  }

  @override
  void dispose() {
    _detail.removeListener(_onDetailChanged);
    _detail.dispose();
    _settings.dispose();
    _stage.dispose();
    super.dispose();
  }

  /// Prices the open charge, and only that charge.
  ///
  /// The card is rebuilt from the session the reply carries, not from the row
  /// the list handed over: that row is what the reader selected and it still
  /// holds the old price, so a refresh alone would put the old figure back.
  Future<void> _saveChargeCost(
    MoneyKeypadResult<ChargeCostField> result,
  ) async {
    final page = _detail.value;
    if (page is! HistoryChargeDetailPage || _savingChargeCost) return;
    setState(() => _savingChargeCost = true);
    final update = await writeChargeCost(
      api: _api,
      session: page.session,
      result: result,
      fallbackCurrency: _settings.value?.chargeCostCurrency ?? 'BRL',
    );
    if (!mounted) return;
    setState(() => _savingChargeCost = false);
    if (update != null && update.ok) {
      // The store is what holds the price now, so the card is rebuilt by
      // re-reading it. The write is also a session change, and the query
      // listens for one; asking here is what makes the new figure land
      // without waiting for that event.
      unawaited(_detail.ask());
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.v2ChargeCostFailed),
        ),
      );
  }

  void _onDetailChanged() {
    if (mounted) setState(() {});
  }

  /// The selected session and everything drawn beside it, as one question.
  ///
  /// The buckets and the summary are read together because they are drawn
  /// together: a chart that answers for a different drive than the header names
  /// is a wrong answer, not an old one.
  Future<HistoryDetailPage?> _readDetail() async {
    switch (_category) {
      case HistoryCategory.trips:
        final id = _selectedTripId;
        if (id == null) return null;
        final stored = await _api.getSession(id);
        if (stored == null) return null;
        final series = await _api.getSeries(id);
        final insightTrips = await _api.getInsightTrips(subjectId: id);
        final places = await _api.getInsightPlaces();
        final priced = await lastPricedChargeBefore(
          _api.store,
          stored.session.startedAtUtcMillis,
        );
        InsightTrip? subject;
        for (final trip in insightTrips.trips) {
          if (trip.id == id) {
            subject = trip;
            break;
          }
        }
        final index = InsightRouteIndex.build(
          insightTrips.trips,
          places.places,
        );
        final insightSelection = subject == null
            ? InsightSelection.none()
            : primaryInsight(
                subject: subject,
                corpus: insightTrips.trips,
                index: index,
                now: DateTime.now(),
              );
        return HistoryTripDetailPage(
          reading: TripDetailReading(
            session: stored.session,
            series: series,
            events: stored.events,
            lastPricedCharge: priced,
            track: stored.track,
          ),
          buckets: reconcileSessionEnergyBuckets(
            [
              for (final interval in series.intervals)
                EnergyBucket.fromInterval(interval),
            ],
            sessionStart: DateTime.fromMillisecondsSinceEpoch(
              stored.session.startedAtUtcMillis,
            ),
          ),
          insightSelection: insightSelection,
          insightTrips: insightTrips.trips,
          places: places.places,
          routeIndex: index,
        );
      case HistoryCategory.charges:
        final id = _selectedChargeId;
        if (id == null) return null;
        final stored = await _api.getSession(id);
        if (stored == null) return null;
        final series = await _api.getSeries(id);
        return HistoryChargeDetailPage(
          reading: ChargeDetailReading(
            session: stored.session,
            series: series,
            events: stored.events,
          ),
        );
      case HistoryCategory.battery:
        final cycle = _selectedCycle;
        if (cycle == null) return null;
        final sessions = await _api.getBatteryCycleSessions(
          ordinal: cycle.ordinal,
        );
        return HistoryCycleDetailPage(cycle: cycle, sessions: sessions);
    }
  }

  void _selectCategory(HistoryCategory category) {
    if (category == _category) return;
    setState(() => _category = category);
    _detail.ask();
  }

  void _openTrip(SessionRecord session) {
    setState(() => _selectedTripId = session.id);
    _detail.ask();
    _stage.expand();
  }

  void _openCharge(SessionRecord session) {
    setState(() => _selectedChargeId = session.id);
    _detail.ask();
    _stage.expand();
  }

  void _openCycle(BatteryCycleSummary cycle) {
    setState(() => _selectedCycle = cycle);
    _detail.ask();
    _stage.expand();
  }

  String? get _selectedId => switch (_category) {
    HistoryCategory.trips => _selectedTripId,
    HistoryCategory.charges => _selectedChargeId,
    HistoryCategory.battery => _selectedCycle?.ordinal.toString(),
  };

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    // The stage's own size, so the fullscreen layout can be laid out at the
    // size it was designed for even while the card is shrinking under it —
    // see [_detailCard].
    return LayoutBuilder(
      builder: (context, constraints) {
        final stageSize = constraints.biggest;
        return ExpandableCardStage(
          stage: _stage,
          expandableIndex: 1,
          expandSemanticsLabel: loc.v2HistoryExpand,
          collapseSemanticsLabel: loc.v2HistoryCollapse,
          slots: [
            // Stable, not size-aware: this slot never changes width, and it
            // holds the list panes' own queries and scroll position. Re-keying
            // it would throw both away every time the card beside it is
            // dragged.
            CardStageSlot.stable(units: 3, child: _listCard(loc)),
            CardStageSlot(
              units: 1,
              builder: (size) => _detailCard(size, stageSize),
            ),
          ],
        );
      },
    );
  }

  /// What the empty stage asks for, in the words of the record beside it.
  String _selectPrompt(AppLocalizations loc) =>
      _category == HistoryCategory.battery
      ? loc.v2CycleSelectPrompt
      : loc.v2HistorySelectPrompt;

  Widget _listCard(AppLocalizations loc) {
    return ClipRRect(
      borderRadius: AppRadii.xlRadius,
      child: Material(
        color: AppThemeColors.of(context).surface,
        child: CategoryMenu<HistoryCategory>(
          selected: _category,
          onSelected: _selectCategory,
          // The panes scroll themselves. A list of records inside the menu's
          // own scroll view has no viewport to be lazy against and builds
          // every session it was given — see [CategoryMenu.detailScrolls].
          detailScrolls: false,
          // No search row. The settings menu has one because it has four
          // categories and a user who arrived looking for one named thing; a
          // rail of two kinds of record is read, not searched.
          groups: [
            CategoryMenuGroup([
              CategoryMenuEntry(
                value: HistoryCategory.trips,
                label: loc.v2HistoryTrips,
                icon: Icons.route,
              ),
              CategoryMenuEntry(
                value: HistoryCategory.charges,
                label: loc.v2HistoryCharges,
                icon: Icons.bolt,
              ),
              CategoryMenuEntry(
                value: HistoryCategory.battery,
                label: loc.v2HistoryBattery,
                icon: Icons.battery_charging_full,
              ),
            ]),
          ],
          detailBuilder: (context, category) => switch (category) {
            HistoryCategory.trips => TripHistoryPane(
              telemetryApi: widget.telemetryApi,
              selectedId: _selectedId,
              onSelected: _openTrip,
            ),
            HistoryCategory.charges => ChargeHistoryPane(
              telemetryApi: widget.telemetryApi,
              selectedId: _selectedId,
              onSelected: _openCharge,
            ),
            HistoryCategory.battery => BatteryHistoryPane(
              telemetryApi: widget.telemetryApi,
              selectedOrdinal: _selectedCycle?.ordinal,
              onSelected: _openCycle,
            ),
          },
        ),
      ),
    );
  }

  Widget _detailCard(CardSize size, Size stageSize) {
    final loc = AppLocalizations.of(context)!;
    final state = _detail.state;

    if (state.isFirstLoad) {
      return const AppCard(child: Center(child: CircularProgressIndicator()));
    }
    final page = state.value;
    if (page == null) {
      return AppCard(
        child: Center(
          child: Text(
            state.errorMessage ?? _selectPrompt(loc),
            style: AppText.body.copyWith(
              color: AppThemeColors.of(context).inkSubtle,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (size != CardSize.fullscreen) {
      return HistoryDetailSummaryCard(page: page);
    }
    // Pinned to the stage's size and clipped, rather than laid out in the box
    // it currently has. The cross-fade back to the docked layout keeps this
    // one on screen while the card is already shrinking under it, and a
    // dashboard re-flowing through every width on its way out is both ugly and
    // a stream of overflow errors. The card it belongs to is exactly this size
    // whenever it is the one being read.
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: stageSize.width,
        maxWidth: stageSize.width,
        minHeight: stageSize.height,
        maxHeight: stageSize.height,
        child: HistoryDetailFullscreen(
          page: page,
          costEditor: HistoryChargeCostEditor(
            defaultCostPerKwh: _settings.value?.defaultChargeCostPerKwh,
            saving: _savingChargeCost,
            onSubmitted: _saveChargeCost,
          ),
        ),
      ),
    );
  }
}
