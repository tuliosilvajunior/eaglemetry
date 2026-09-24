import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:capy_ui/capy_ui.dart';

import '../core/android_auto_api.dart';
import '../core/app_experience_controller.dart';
import '../core/app_navigation_controller.dart';
import '../core/carplay_api.dart';
import '../core/live_trip_can_hub.dart';
import '../core/projection_presence_api.dart';
import '../core/range_estimate_controller.dart';
import '../core/vehicle_state_controller.dart';
import '../l10n/app_localizations.dart';
import 'android_auto_home_v2_screen.dart';
import 'experience_welcome_dialog.dart';
import 'carplay_home_v2_screen.dart';
import 'charging/charging_v2_screen.dart';
import 'compass_readout.dart';
import 'efficiency_readout.dart';
import 'history/history_v2_screen.dart';
import 'incline_readout.dart';
import 'settings_menu.dart';
import 'shell_climate_bar.dart';
import 'sync/sync_v2_screen.dart';
import 'trips/trips_v2_screen.dart';

/// Identity only. Declaration order carries no meaning — the order the user
/// sees, and the order the body is indexed by, is
/// `_AppShellV2State._destinations`. Add a destination wherever you like here,
/// then put it where it belongs in that list.
///
/// Settings is deliberately not here. It is a floating menu opened from the
/// gear beside the tab row, not a destination the roll can land on: settings
/// are something you go and do to the app, then leave, and giving them a tab
/// spends a permanent slot on a screen nobody drives with.
enum _V2Destination { trips, charging, history, sync, carplay, androidAuto }

class AppShellV2 extends StatefulWidget {
  const AppShellV2({
    this.carplayApi,
    this.androidAutoApi,
    this.projectionPresenceApi,
    super.key,
  });

  /// Injected into the CarPlay surfaces and into the shell's own connection
  /// check (see `_carplayApi`). Only tests pass it: without a seam here a
  /// shell test drives the real platform channels and cannot assert
  /// activation or connection behavior.
  final CarplayApi? carplayApi;

  /// The Android Auto twin of [carplayApi]. Only tests pass it.
  final AndroidAutoApi? androidAutoApi;

  /// Answers which phone is actually connected. Only tests pass it.
  final ProjectionPresenceApi? projectionPresenceApi;

  @override
  State<AppShellV2> createState() => _AppShellV2State();
}

class _AppShellV2State extends State<AppShellV2>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  _V2Destination _selected = _V2Destination.trips;

  /// Destinations the user has actually opened.
  ///
  /// A tab body stays mounted once built — see [_KeepAlivePage] — which is
  /// what preserves scroll and selection across tab switches. Building every
  /// destination eagerly instead would run an unvisited screen's `initState`
  /// telemetry loads at boot, so only visited destinations are materialized;
  /// the rest stay empty placeholders until first selection.
  late final Set<_V2Destination> _visited = {_selected};

  /// Destinations the roll has actually come to rest on, as opposed to
  /// merely scrolled past while jumping further. Feeds [EntranceGate]: a
  /// destination rolled *through* is built (so the pass-through shows its
  /// real card layout) but not yet arrived (so its charts do not spend their
  /// entrance on a screen the user never stopped at). Only ever grows, which
  /// is what makes an entrance a once-per-destination event.
  late final Set<_V2Destination> _arrived = {_selected};

  /// Where the roll is currently at rest — the one destination, as opposed to
  /// [_arrived]'s ever-growing set of every destination ever landed on.
  ///
  /// Chrome that changes the **size** of the body reads this and not
  /// [_selected], so the strip travels between rolls rather than during one.
  /// A footer that collapses while the roll runs re-measures the `PageView`
  /// on every frame of it, and both pages visible mid-roll re-layout and
  /// re-shape all their text each time — which is felt as a stutter on
  /// exactly the one destination that hides the strip.
  late _V2Destination _settled = _selected;

  /// Drives the drag-to-fullscreen gesture for whichever destination is
  /// currently staged — see [_stagedDestinations]. Owned one level above any
  /// destination whose cards can expand, because the gesture has to hide
  /// chrome (the pill row) that lives outside that destination's own
  /// subtree. A single shared instance is safe because only one destination
  /// is ever visible at a time; [_selectTab] collapses it before rolling
  /// away from a staged one, so a card left mid-gesture never strands the
  /// chrome hidden with nothing left to collapse it.
  late final CardStageController _cardStage;

  late final PageController _pageController;

  /// Feeds the pill indicator the roll's own continuous position, so it
  /// cannot drift from the cards moving under it. See `PageTabPosition`.
  late final PageTabPosition _pillPosition;

  /// One 60 Hz Roadcast client for the footer cards. Incline and smoothness
  /// share it so the strip does not open two native caches.
  late final LiveTripCanHub _liveCan = LiveTripCanHub();

  /// Shared with every CarPlay surface this shell builds, so the connection
  /// check below and the surfaces themselves agree on one underlying host
  /// connection instead of each opening its own.
  late final CarplayApi _carplayApi = widget.carplayApi ?? CarplayApi();

  /// The Android Auto host. A separate service, a separate renderer and a
  /// separate channel — the two stacks share only the tab rule that decides
  /// which of them the user sees.
  late final AndroidAutoApi _androidAutoApi =
      widget.androidAutoApi ?? AndroidAutoApi();

  StreamSubscription<CarplayStatus>? _carplayStatusSub;

  StreamSubscription<AndroidAutoStatus>? _androidAutoStatusSub;

  /// Reads the OEM stacks' own connection state. Separate from [_carplayApi]
  /// on purpose: that one describes this app's render surface, and an attached
  /// surface with no phone looks exactly like an attached surface with one.
  late final ProjectionPresenceApi _presenceApi =
      widget.projectionPresenceApi ?? ProjectionPresenceApi();

  StreamSubscription<ProjectionPresence>? _presenceSub;

  bool _climateBarEnabled = AppExperienceController.instance.climateBarEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    VehicleStateController.instance.start();
    RangeEstimateController.instance.start();
    _cardStage = CardStageController(vsync: this);
    _pageController = PageController(
      initialPage: _destinations.indexOf(_selected),
    );
    _pillPosition = PageTabPosition(_pageController);
    AppExperienceController.instance.addListener(_onExperienceChanged);
    AppNavigationController.instance.addListener(_onNavigationRequested);
    if (AppExperienceController.instance.projectionEnabled) _watchProjection();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        showExperienceWelcomeDialog(context);
        _onNavigationRequested();
      }
    });
  }

  /// Opens the destination something outside the app asked for.
  ///
  /// Two ask today, and each replaces a factory screen this app suppresses:
  /// the charge plug, and a phone that arrives. A request describes one launch,
  /// so it is cleared as soon as it is answered — kept, it would open that
  /// screen again at the next unrelated rebuild.
  ///
  /// A projection request is the one that cannot always be answered at once.
  /// The tab exists only while the phone is reported, and on a cold start this
  /// shell is still reading presence when the request arrives. So a request for
  /// a tab that is not there yet is **held** while presence is unknown, and
  /// the presence handler in [_watchProjection] runs this again when the
  /// reading lands. Once presence is known and the tab is still absent, the
  /// answer is no, and the request is
  /// dropped rather than left to fire at some later connection.
  void _onNavigationRequested() {
    final nav = AppNavigationController.instance;
    final pending = nav.pendingDestination;
    if (pending == null) return;
    final target = _destinationFor(pending);
    if (target == null) {
      nav.clearPending();
      return;
    }
    if (_destinations.contains(target)) {
      nav.clearPending();
      _selectTab(target);
      return;
    }
    if (_presenceKnownFor(target)) nav.clearPending();
  }

  /// The tab a destination id names, or null for an id this shell has not got.
  static _V2Destination? _destinationFor(String destination) =>
      switch (destination) {
        AppNavigationController.charging => _V2Destination.charging,
        AppNavigationController.carplay => _V2Destination.carplay,
        AppNavigationController.androidAuto => _V2Destination.androidAuto,
        _ => null,
      };

  /// Whether presence has answered for this tab yet. A tab that does not
  /// depend on a phone is always answered.
  bool _presenceKnownFor(_V2Destination destination) => switch (destination) {
    _V2Destination.carplay => _presence.carplay != PresenceState.unknown,
    _V2Destination.androidAuto =>
      _presence.androidAuto != PresenceState.unknown,
    _ => true,
  };

  /// Starts looking for both OEM projection stacks and for the phone.
  ///
  /// Three sources, and the tab rule needs all of them: each stack says
  /// whether its own service is reachable, and the presence monitor says which
  /// phone is actually plugged in — see [_projectionTabs].
  ///
  /// Nothing here runs while the beta is off, which is the point: the first
  /// call over each channel is what makes the platform side bind that service,
  /// so an untouched channel leaves it unstarted rather than started and
  /// ignored.
  void _watchProjection() {
    // A read in flight when the beta is switched off must not put a
    // destination back — the late reply is about a service we have stopped
    // caring about.
    bool stale() =>
        !mounted || !AppExperienceController.instance.projectionEnabled;

    void applyCarplay(CarplayStatus status) {
      if (stale()) return;
      _setVisibility(() => _carplayBound = status.bound);
    }

    void applyAndroidAuto(AndroidAutoStatus status) {
      if (stale()) return;
      _setVisibility(() => _androidAutoBound = status.bound);
    }

    void applyPresence(ProjectionPresence presence) {
      if (stale()) return;
      final previous = _presence;
      _setVisibility(() {
        _presence = presence;
        // The app suppresses the factory CarPlay and Android Auto popups, so
        // plugging a phone in must land on the phone's tab here instead.
        //
        // A *transition* opens it, and only from a state we know: presence
        // starts `unknown`, so treating the first read as an arrival would
        // take the screen on every launch with a phone already plugged in.
        final arrived = _arrivedTab(previous, presence);
        if (arrived != null && _destinations.contains(arrived)) {
          _selected = arrived;
          _visited.add(_selected);
          _arrived.add(_selected);
          // A snap: nothing is animating, so the strip follows at once.
          _settled = _selected;
        }
      });
      // A cold start opens with a request for the phone's tab and no presence
      // yet, so the request waits for this reading. Outside the setState
      // above, because answering it selects a tab and calls its own.
      _onNavigationRequested();
    }

    _carplayApi.getStatus().then(applyCarplay);
    _carplayStatusSub = _carplayApi.statusStream().listen(applyCarplay);
    _androidAutoApi.getStatus().then(applyAndroidAuto);
    _androidAutoStatusSub = _androidAutoApi.statusStream().listen(
      applyAndroidAuto,
    );
    _presenceApi.getPresence().then(applyPresence);
    _presenceSub = _presenceApi.presenceStream().listen(applyPresence);
  }

  /// Reacts to any Settings choice this shell draws from, while the floating
  /// settings surface is still open.
  ///
  /// The climate bar needs a rebuild only when its flag moves. The projection
  /// beta is handled in [_onProjectionBetaChanged], which is guarded against
  /// being run twice for a switch that did not move.
  void _onExperienceChanged() {
    _onProjectionBetaChanged();
    final climateBarEnabled =
        AppExperienceController.instance.climateBarEnabled;
    if (climateBarEnabled == _climateBarEnabled) return;
    _climateBarEnabled = climateBarEnabled;
    if (mounted) setState(() {});
  }

  /// Reacts to the beta being switched in Config, without a restart.
  ///
  /// Turning it off drops every subscription and both destinations with them;
  /// turning it back on re-runs the same probes [initState] would have.
  void _onProjectionBetaChanged() {
    final enabled = AppExperienceController.instance.projectionEnabled;
    if (enabled == (_carplayStatusSub != null)) return;
    if (enabled) {
      _watchProjection();
    } else {
      _carplayStatusSub?.cancel();
      _carplayStatusSub = null;
      _androidAutoStatusSub?.cancel();
      _androidAutoStatusSub = null;
      _presenceSub?.cancel();
      _presenceSub = null;
      _setVisibility(() {
        _carplayBound = false;
        _androidAutoBound = false;
        _presence = ProjectionPresence.unknown;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    VehicleStateController.instance.stop();
    RangeEstimateController.instance.stop();
    _cardStage.dispose();
    _pillPosition.dispose();
    _pageController.dispose();
    _liveCan.dispose();
    AppExperienceController.instance.removeListener(_onExperienceChanged);
    AppNavigationController.instance.removeListener(_onNavigationRequested);
    _carplayStatusSub?.cancel();
    _androidAutoStatusSub?.cancel();
    _presenceSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Polling the vehicle every few seconds behind another app is wasted work
    // on a head unit. Resuming issues an immediate read, so returning to the
    // app never shows a stale value.
    //
    // This stays beside `AppForegroundGate`, and the two are not the same
    // statement. The gate disarms a timer while the Activity is off screen and
    // re-arms it on return; `stop` here says the shell does not want these two
    // controllers running at all. The gate cannot say that, because it cannot
    // tell a loop nobody wants from one the car hid. It is also stricter than
    // the gate on purpose: these snapshots feed a card, so losing focus is
    // enough to stop them, while the gate keeps a visible-but-unfocused app
    // reading.
    if (state == AppLifecycleState.resumed) {
      VehicleStateController.instance.start();
      RangeEstimateController.instance.start();
      // A connection edge broadcast while this app was in the background may
      // never have reached it. The getters are cheap, so resuming asks again
      // rather than trusting the last edge seen.
      if (_presenceSub != null) _presenceApi.refresh();
    } else {
      VehicleStateController.instance.stop();
      RangeEstimateController.instance.stop();
    }
  }

  /// The destinations this shell shows, in the order the user sees them.
  ///
  /// The single source of order. The pills and the bodies are both built from
  /// this one list, so they cannot disagree — before, each conditional
  /// destination was written twice, once per list, and the two only agreed
  /// because every conditional one happened to sit last.
  ///
  /// A destination appears here only while it should be reachable, so this is
  /// also where a condition goes. Today the only condition is
  /// [_projectionTabs] — the CarPlay beta being on *and* a phone the OEM
  /// stack reports as connected. Every half of that can flip at any time while
  /// the app runs, so unlike a settled-once flag, every change has to notify
  /// through [_setVisibility] so the selection — and the page the roll is
  /// sitting on — are reconciled with it.
  List<_V2Destination> get _destinations => [
    if (_projectionTabs.carplay) _V2Destination.carplay,
    if (_projectionTabs.androidAuto) _V2Destination.androidAuto,
    _V2Destination.trips,
    _V2Destination.charging,
    _V2Destination.history,
    _V2Destination.sync,
  ];

  /// Which projection tabs to show.
  ///
  /// One beta switch feeds both protocols, because the user is choosing
  /// whether the app shows their phone at all, not which phone they own.
  ProjectionTabs get _projectionTabs => resolveProjectionTabs(
    presence: _presence,
    carplayEnabled: AppExperienceController.instance.projectionEnabled,
    androidAutoEnabled: AppExperienceController.instance.projectionEnabled,
    carplayBound: _carplayBound,
    androidAutoBound: _androidAutoBound,
  );

  /// What the OEM stacks report about the phone. Starts unknown, which is what
  /// makes [_carplayBound] the fallback until the first read lands.
  ProjectionPresence _presence = ProjectionPresence.unknown;

  /// Whether we are bound to the head unit's OEM CarPlay service — see
  /// `CarplayStatus.bound`. This is **not** a phone: the OEM app is installed
  /// on every one of these head units, so this is true with nothing plugged
  /// in. It is used only where presence is unknown, because a card that would
  /// have worked must not be hidden by a probe that failed. Starts `false` so
  /// the tab is absent until the first status read lands, rather than flashing
  /// in before we know — and stays false for as long as the beta is off, since
  /// that read never happens.
  bool _carplayBound = false;

  /// The Android Auto twin of [_carplayBound], and just as weak on its own:
  /// `com.njda.aauto` is installed on every one of these head units too.
  bool _androidAutoBound = false;

  /// Destinations whose cards ride [_cardStage] and therefore need the
  /// shell's chrome wired to it. Every other destination renders its pill row
  /// un-animated. The CarPlay surface is the only card that expands today.
  static const _stagedDestinations = {
    _V2Destination.carplay,
    _V2Destination.androidAuto,
  };

  /// Which projection tab a phone has just arrived on, if any.
  ///
  /// Only a `disconnected` to `connected` step counts. `unknown` is the state
  /// before the first read lands, and a phone that was already there when the
  /// app opened did not arrive.
  static _V2Destination? _arrivedTab(
    ProjectionPresence previous,
    ProjectionPresence next,
  ) {
    if (previous.carplay == PresenceState.disconnected &&
        next.carplay == PresenceState.connected) {
      return _V2Destination.carplay;
    }
    if (previous.androidAuto == PresenceState.disconnected &&
        next.androidAuto == PresenceState.connected) {
      return _V2Destination.androidAuto;
    }
    return null;
  }

  /// Applies a change in which destinations are shown, and moves the user off
  /// one that has stopped being shown.
  void _setVisibility(VoidCallback change) {
    setState(() {
      change();
      final destinations = _destinations;
      if (!destinations.contains(_selected)) {
        _selected = destinations.first;
        _visited.add(_selected);
        _arrived.add(_selected);
        // A snap, not a roll — see below. There is no settling callback to
        // wait for, so the strip follows the jump.
        _settled = _selected;
      }
    });
    // A destination's presence changing can shift every other one's index in
    // `_destinations` without moving the user anywhere the roll should
    // animate to: the page the controller is sitting on was aimed at a
    // destination, not a position, so it has to be re-pointed at that same
    // destination's new index — a silent snap, not a roll.
    if (_pageController.hasClients) {
      _pageController.jumpToPage(_destinations.indexOf(_selected));
    }
  }

  // The design system's own motion token. Everything that rides on this — the
  // pill sliding between tabs, and `_arrived` opening a destination's chart
  // gate when the roll lands — is driven off the same `PageController`, so
  // raising or lowering it here moves all of it together.
  //
  // One knob left deliberately alone: this is a flat duration, so a jump
  // across three tabs travels three times the distance in the same time. If a
  // wider tab row ever makes that read as a lurch, scale it by the destination
  // distance rather than slowing the single-step case down to match.
  static const _tabRollDuration = AppMotion.slow;

  void _selectTab(_V2Destination destination) {
    if (destination == _selected) return;
    HapticFeedback.selectionClick();
    // Leaving a staged destination mid-gesture would otherwise strand the
    // shell with its chrome hidden and no card left to collapse it back.
    _cardStage.collapse();
    final destinations = _destinations;
    final from = destinations.indexOf(_selected);
    final to = destinations.indexOf(destination);
    final lo = from < to ? from : to;
    final hi = from < to ? to : from;
    setState(() {
      _selected = destination;
      // A jump of more than one step rolls through whichever destinations
      // sit between — mark those visited too, not just the one landed on, so
      // they render their real content instead of a blank flash while
      // passing through.
      _visited.addAll(destinations.sublist(lo, hi + 1));
    });
    _pageController
        .animateToPage(to, duration: _tabRollDuration, curve: AppMotion.curve)
        .then((_) => _onRollSettled(destination));
  }

  /// Called when a roll finishes. `animateToPage`'s future also completes
  /// when the roll it started was *interrupted* — tap three tabs in quick
  /// succession and every abandoned future fires too — so the destination it
  /// was heading for is not necessarily where the shell ended up. Only the
  /// destination still selected has actually arrived.
  void _onRollSettled(_V2Destination destination) {
    if (!mounted || _selected != destination) return;
    final entered = _arrived.add(destination);
    final restedElsewhere = _settled != destination;
    if (!entered && !restedElsewhere) return;
    setState(() => _settled = destination);
  }

  Widget _destination(_V2Destination destination, Widget Function() build) {
    return _KeepAlivePage(
      child: !_visited.contains(destination)
          ? const SizedBox.shrink()
          : EntranceGate(open: _arrived.contains(destination), child: build()),
    );
  }

  String _label(AppLocalizations loc, _V2Destination destination) {
    return switch (destination) {
      _V2Destination.trips => loc.navTrips,
      _V2Destination.charging => loc.navCharging,
      _V2Destination.history => loc.navHistory,
      _V2Destination.sync => loc.navSync,
      _V2Destination.carplay => loc.navCarplay,
      _V2Destination.androidAuto => loc.navAndroidAuto,
    };
  }

  /// Whether the settings menu is open, so the gear keeps the selection fill
  /// for as long as the surface it opened is visible.
  bool _settingsOpen = false;

  Future<void> _openSettings() async {
    if (_settingsOpen) return;
    setState(() => _settingsOpen = true);
    try {
      await showSettingsMenu(context);
    } finally {
      if (mounted) setState(() => _settingsOpen = false);
    }
  }

  /// Built fresh on every build, and deliberately not memoized: `isActive` is
  /// read at build time, so the CarPlay surface learns it is no longer
  /// selected through `didUpdateWidget`. Wrapping a child in `const` or caching
  /// it here stops that flag propagating, and the app keeps the OEM renderer
  /// after the user has left the tab.
  Widget _screen(
    AppLocalizations loc,
    _V2Destination destination,
    _V2Destination selected,
  ) {
    return switch (destination) {
      _V2Destination.trips => TripsV2Screen(
        title: loc.navTrips,
        isActive: selected == _V2Destination.trips,
      ),
      _V2Destination.charging => ChargingV2Screen(title: loc.navCharging),
      _V2Destination.history => HistoryV2Screen(title: loc.navHistory),
      _V2Destination.sync => SyncV2Screen(
        title: loc.navSync,
        androidBetaUrl: const String.fromEnvironment('COMPANION_ANDROID_URL'),
        iosBetaUrl: const String.fromEnvironment('COMPANION_IOS_URL'),
        forbiddenApkUrl: const String.fromEnvironment(
          'COMPANION_DIRECT_APK_URL',
        ),
      ),
      _V2Destination.carplay => CarplayHomeV2Screen(
        title: loc.navCarplay,
        carplayApi: _carplayApi,
        isActive: selected == _V2Destination.carplay,
        stage: _cardStage,
      ),
      // `isActive` is read fresh at every build and the child is never const
      // or memoized: freezing it would leave this app holding the OEM renderer
      // after the user rolls away, which is a direct R1 violation.
      _V2Destination.androidAuto => AndroidAutoHomeV2Screen(
        title: loc.navAndroidAuto,
        androidAutoApi: _androidAutoApi,
        isActive: selected == _V2Destination.androidAuto,
        stage: _cardStage,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final destinations = _destinations;
    // Resolved for this frame rather than read straight off `_selected`, as a
    // floor under [_setVisibility]'s write-back: forgetting to call that can
    // never leave this frame pointing at a destination that is not shown.
    final selected = destinations.contains(_selected)
        ? _selected
        : destinations.first;

    return AppJourneyScaffold<_V2Destination>(
      tabs: [
        for (final destination in destinations)
          TabItem(value: destination, label: _label(loc, destination)),
      ],
      selected: selected,
      onSelected: _selectTab,
      position: _pillPosition,
      stage: _stagedDestinations.contains(selected) ? _cardStage : null,
      trailing: SquareIconButton(
        icon: Icons.settings,
        // As tall as a pill. The gear stands beside the tab row, so a smaller
        // square would read as a lesser control than the tabs it sits with.
        size: AppSizes.minTouchTarget,
        tooltip: loc.navSettings,
        selected: _settingsOpen,
        onPressed: _openSettings,
      ),
      // Journey chrome, so it is built here rather than inside the roll: it
      // survives every tab switch, and it keeps whichever reading it is
      // showing.
      //
      // The reading feeds itself. Nothing live is held in this state and
      // handed down, because the footer sits above the `PageView`: a value
      // kept here would rebuild every mounted destination at the rate it
      // changes. `_cardStage` goes down so the reading can stop sampling once
      // a card has pushed the strip off screen.
      footer: InstantReadoutBar(
        readings: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EfficiencyReadout(
                stage: _cardStage,
                liveCan: _liveCan,
                samplingEnabled: _settled != _V2Destination.history,
              ),
              const SizedBox(width: AppSpacing.gridGutter),
              SizedBox(
                width: 280,
                child: InclineReadout(
                  stage: _cardStage,
                  liveCan: _liveCan,
                  samplingEnabled: _settled != _V2Destination.history,
                ),
              ),
              const SizedBox(width: AppSpacing.gridGutter),
              // Square, and by ratio rather than by a number: the strip is a
              // quarter of the screen height, so a fixed width would only be
              // square on one display. The row stretches its children, so the
              // height is given and the ratio decides the width.
              AspectRatio(
                aspectRatio: 1,
                child: CompassReadout(stage: _cardStage),
              ),
            ],
          ),
        ],
      ),
      // History is one full-bleed surface, so it takes the strip's share of
      // the screen the same way an expanding card does. Only the tabs stay.
      //
      // Read off [_settled] rather than `selected`: the handover happens
      // between rolls, so the body keeps one height for the whole roll and
      // the two pages moving across it are measured once instead of on every
      // frame. Leaving history is the same trade in reverse — the strip comes
      // back after the roll lands, not while it travels.
      // Deliberately not `footer`, and deliberately given no `stage`: this
      // strip is the vehicle's, not the journey's, so a card that grows to
      // fullscreen must not be able to take it away. See
      // `AppJourneyScaffold.staticBar`.
      staticBar: _climateBarEnabled ? const ShellClimateBar() : null,
      footerVisible: _settled != _V2Destination.history,
      body: PageView(
        controller: _pageController,
        // The roll only ever runs from a pill tap, via
        // `PageController.animateToPage` in [_selectTab] — manual swiping
        // would let the user drag past a destination `_visited` never marked.
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final destination in destinations)
            // Keyed by destination, not by position. A conditional
            // destination appearing or disappearing shifts every one after
            // it in this list — without a key the state of one screen is
            // re-parented onto the next one's slot.
            KeyedSubtree(
              key: ValueKey(destination),
              child: _destination(
                destination,
                () => _screen(loc, destination, selected),
              ),
            ),
        ],
      ),
    );
  }
}

/// Holds one destination's body alive once it has been built.
///
/// Not building a destination twice is only half of "build it once and keep
/// it": [PageView] materializes its pages lazily and drops the ones scrolled
/// out of view, taking their `State` with them. Without this, a paused
/// simulation or a resized card would be forgotten on every tab switch — just
/// for a different reason than the `IndexedStack` swap this replaced. A page
/// only has to ask to be kept; `PageView`'s child delegate wraps every page in
/// an `AutomaticKeepAlive` already.
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
