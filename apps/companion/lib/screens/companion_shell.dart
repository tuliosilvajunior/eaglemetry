import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../abrp/abrp_settings_store.dart';
import '../abrp/abrp_telemetry_forwarder.dart';
import '../auth/auth_controller.dart';
import '../ble/live_telemetry_ble_client.dart';
import '../l10n/app_localizations.dart';
import '../settings/companion_theme_controller.dart';
import '../settings/nominatim_opt_in_store.dart';
import '../sync/journey_store.dart';
import '../sync/local_telemetry_source.dart';
import '../sync/pairing_controller.dart';
import '../sync/cloud_migration.dart';
import '../sync/preference_control_sync.dart';
import '../sync/sync_controller.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'insights_screen.dart';
import 'journeys_screen.dart';
import 'settings_screen.dart';

/// The phone's destinations, in the order the reader meets them.
///
/// Trips and charges are separate destinations rather than one history with a
/// switch inside it, because on a phone the switch is a second place to tap
/// before the answer appears.
enum CompanionTab {
  trips,
  charges,
  journeys,
  insights,
  battery,
  sync,
  settings;

  /// The destinations the shell draws, in order.
  ///
  /// [battery] is absent: it has no screen yet, and a pill that opens a line
  /// saying so costs the reader a tap to be told nothing. It keeps its enum
  /// value and its body, so bringing it back is adding it to this list.
  ///
  /// Everything positional reads this rather than `values`, because a hidden
  /// destination still holds its ordinal and a page index taken from `index`
  /// would then point one place past where the reader is.
  static const List<CompanionTab> visible = [
    trips,
    charges,
    journeys,
    insights,
    sync,
    settings,
  ];

  /// Where this destination sits among the visible ones, or -1 when hidden.
  int get position => visible.indexOf(this);
}

/// The phone shell: the visible destinations roll sideways, over a pill row.
///
/// The bodies roll rather than cut, so the pill is driven by the roll itself
/// through [PageTabPosition] and cannot drift from the page underneath it. The
/// pill row scrolls on the same value: five localized labels are wider than a
/// phone, and a destination the reader cannot see is one they cannot reach.
class CompanionShell extends StatefulWidget {
  const CompanionShell({
    required this.pairing,
    required this.store,
    required this.source,
    required this.theme,
    this.journeys,
    this.auth,
    this.sync,
    this.ble,
    this.abrpForwarder,
    this.abrpSettings,
    this.nominatimOptIn,
    this.control,
    this.cloudMigration,
    super.key,
  });

  final PairingController pairing;

  /// The read surface behind every list and detail on this phone.
  final TelemetryStore store;

  final HistoricalTelemetrySource source;
  final JourneyStore? journeys;
  final SyncController? sync;

  /// Optional live BLE streaming client.
  final LiveTelemetryBleClient? ble;

  /// Optional ABRP telemetry forwarder.
  final AbrpTelemetryForwarder? abrpForwarder;

  /// Optional ABRP settings store.
  final AbrpSettingsStore? abrpSettings;

  final NominatimOptInStore? nominatimOptIn;

  /// The Lane C control-plane state, when this build reaches the cloud.
  final PreferenceControlController? control;

  /// One-time cloud migration for existing phone-only history.
  final CloudMigration? cloudMigration;

  /// What the app is drawn with, and the one place the reader changes it.
  final CompanionThemeController theme;

  /// The account form. Absent when this build carries no account server.
  final AuthController? auth;

  @override
  State<CompanionShell> createState() => _CompanionShellState();
}

class _CompanionShellState extends State<CompanionShell> {
  /// Sync is where the app opens while nothing is paired: an empty trip list is
  /// not an answer the reader can act on, and pairing is what makes it one.
  late CompanionTab _tab = widget.pairing.isPaired
      ? CompanionTab.trips
      : CompanionTab.sync;

  late final PageController _pages = PageController(initialPage: _tab.position);
  late final PageTabPosition _position = PageTabPosition(_pages);
  final _pillScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _position.addListener(_followRoll);
  }

  @override
  void dispose() {
    _position
      ..removeListener(_followRoll)
      ..dispose();
    _pillScroll.dispose();
    _pages.dispose();
    super.dispose();
  }

  /// Keeps the pill row in step with the roll.
  ///
  /// The offset is the roll's own fraction of the scrollable width, so the
  /// first destination sits at the left edge, the last at the right, and every
  /// one between them is proportional. It is a jump, not an animation: the
  /// value it follows is already continuous, and a second animation over it
  /// would lag the pills behind the pages they name.
  void _followRoll() {
    if (!_pillScroll.hasClients) return;
    final extent = _pillScroll.position.maxScrollExtent;
    if (extent <= 0) return;
    final span = CompanionTab.visible.length - 1;
    final fraction = (_position.value / span).clamp(0.0, 1.0);
    _pillScroll.jumpTo(fraction * extent);
  }

  void _select(CompanionTab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    _pages.animateToPage(
      tab.position,
      duration: AppMotion.base,
      curve: AppMotion.curve,
    );
  }

  JourneyStore? _resolveJourneyStore() {
    final journeys = widget.journeys;
    if (journeys != null) return journeys;
    final source = widget.source;
    if (source is LocalTelemetrySource) {
      return JourneyStore(source.archive);
    }
    return null;
  }

  Widget _body(CompanionTab tab, AppLocalizations l10n) {
    final journeyStore = _resolveJourneyStore();
    return switch (tab) {
      CompanionTab.trips => HistoryScreen(
        store: widget.store,
        source: widget.source,
        tab: HistoryTab.trips,
      ),
      CompanionTab.charges => HistoryScreen(
        store: widget.store,
        source: widget.source,
        tab: HistoryTab.charges,
      ),
      CompanionTab.journeys =>
        journeyStore != null
            ? JourneysScreen(
                store: widget.store,
                source: widget.source,
                journeyStore: journeyStore,
              )
            : _ComingSoon(title: l10n.navJourneys),
      CompanionTab.insights => InsightsScreen(
        store: widget.store,
        source: widget.source,
        nominatimOptIn: widget.nominatimOptIn,
        onOpenSettings: () => _select(CompanionTab.settings),
      ),
      CompanionTab.battery => _ComingSoon(title: l10n.navBattery),
      CompanionTab.sync => HomeScreen(
        pairing: widget.pairing,
        sync: widget.sync,
        ble: widget.ble,
        abrpForwarder: widget.abrpForwarder,
        abrpSettings: widget.abrpSettings,
        cloudMigration: widget.cloudMigration,
        active: _tab == CompanionTab.sync,
      ),
      CompanionTab.settings => SettingsScreen(
        theme: widget.theme,
        auth: widget.auth,
        abrpSettings: widget.abrpSettings,
        abrpForwarder: widget.abrpForwarder,
        nominatimOptIn: widget.nominatimOptIn,
        control: widget.control,
      ),
    };
  }

  String _label(CompanionTab tab, AppLocalizations l10n) {
    return switch (tab) {
      CompanionTab.trips => l10n.navTrips,
      CompanionTab.charges => l10n.navCharges,
      CompanionTab.journeys => l10n.navJourneys,
      CompanionTab.insights => l10n.navInsights,
      CompanionTab.battery => l10n.navBattery,
      CompanionTab.sync => l10n.navSync,
      CompanionTab.settings => l10n.navSettings,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: PageView(
          controller: _pages,
          onPageChanged: (index) =>
              setState(() => _tab = CompanionTab.visible[index]),
          children: [for (final tab in CompanionTab.visible) _body(tab, l10n)],
        ),
      ),
      // The pill row sits on the canvas, with no bar behind it. The pill is
      // the only mark this chrome makes: a surface and a rule under it would
      // draw a second boundary around a shape that already reads as one.
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
          // The height is stated, not measured. A horizontal
          // `SingleChildScrollView` is unbounded across its scroll axis, so
          // inside the loose constraints `Scaffold` gives a bottom bar it
          // grows to the whole screen and the pill row becomes the app.
          child: SizedBox(
            height: AppSizes.minTouchTarget,
            child: SingleChildScrollView(
              controller: _pillScroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
              child: PillTabBar<CompanionTab>(
                items: [
                  for (final tab in CompanionTab.visible)
                    TabItem(value: tab, label: _label(tab, l10n)),
                ],
                selected: _tab,
                onSelected: _select,
                position: _position,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A destination that is named but not built.
///
/// It says so rather than showing an empty list: an empty list is a claim that
/// the phone holds nothing, and here the phone has simply not been asked.
class _ComingSoon extends StatelessWidget {
  const _ComingSoon({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ScreenTitle(title),
        Expanded(
          child: Center(
            child: Text(
              l10n.navComingSoon,
              style: AppText.body.copyWith(color: colors.inkMuted),
            ),
          ),
        ),
      ],
    );
  }
}

/// The heading a phone destination opens with.
///
/// It lives here rather than in `capy_ui` because it is the shell's chrome:
/// every page under this pill row carries one, and a page that drew its own
/// would be free to disagree with its neighbours about where the title sits.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.x6,
        AppSpacing.x6,
        AppSpacing.x6,
        AppSpacing.x4,
      ),
      child: Text(text, style: AppText.cardTitle.copyWith(color: colors.ink)),
    );
  }
}
