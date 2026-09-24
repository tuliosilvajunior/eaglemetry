import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

import 'core/app_experience_controller.dart';
import 'core/app_navigation_controller.dart';
import 'core/developer_tools_gate.dart';
import 'core/efficiency_unit.dart';
import 'core/image_cache_budget.dart';
import 'core/preference_sync.dart';
import 'core/telemetry_api.dart';
import 'core/telemetry_scope.dart';
import 'core/theme_controller.dart';
import 'design_system/design_system.dart';
import 'l10n/app_localizations.dart';
import 'screens/charging/charging_sessions_screen.dart';
import 'screens/helpers_screen.dart';
import 'screens/history_revamp_screen.dart';
import 'screens/history_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/trips/trip_sessions_screen.dart';
import 'screens/roadcast_trace_screen.dart';
import 'screens_v2/app_shell_v2.dart';
import 'screens_v2/experience_welcome_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  applyImageCacheBudget();
  await (
    ThemeController.instance.load(),
    EfficiencyUnitController.instance.load(),
    AppExperienceController.instance.load(),
  ).wait;
  applyImmersiveMode();
  runApp(const CapyEnergyApp());
  // Not awaited: the app opens on its usual screen, and moves if the launch
  // asked for another one. Awaiting it would hold the first frame behind a
  // bridge call for a screen most launches never ask for.
  AppNavigationController.instance.loadPending(TelemetryApi.shared);
  // Not awaited: the preference rows are best-effort, and the car's own
  // controllers remain the truth whatever the sync answers.
  PreferenceSyncController.instance.start(TelemetryApi.shared);
}

/// Hides or shows the system bars, as the user selected in Settings.
///
/// Called at startup, on every resume, and when the setting changes. Once is
/// not enough: Android restores the bars when the activity is recreated, and
/// when another activity or a system dialog comes in front and goes away
/// again. The mode is a request about the current window, not a permanent
/// property of the app.
void applyImmersiveMode() {
  final experience = AppExperienceController.instance;
  if (experience.immersiveEnabled) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    return;
  }
  // The windowed mode keeps the navigation bar, because it is how the user
  // leaves the app. Only the status bar is optional here, and `manual` is the
  // one mode that can name the bars one at a time.
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: [
      if (!experience.statusBarHidden) SystemUiOverlay.top,
      SystemUiOverlay.bottom,
    ],
  );
}

class CapyEnergyApp extends StatefulWidget {
  const CapyEnergyApp({super.key});

  @override
  State<CapyEnergyApp> createState() => _CapyEnergyAppState();
}

class _CapyEnergyAppState extends State<CapyEnergyApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The setting lives in one place, and the window is told about it here,
    // so a screen that flips the switch does not also have to call the
    // system chrome itself.
    AppExperienceController.instance.addListener(applyImmersiveMode);
  }

  @override
  void dispose() {
    AppExperienceController.instance.removeListener(applyImmersiveMode);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) applyImmersiveMode();
  }

  // ThemeData is not const and is expensive to assemble. These are invariant
  // for the process, so they are built once instead of on every theme or
  // experience notification.
  static final _legacyLight = AutomotiveTheme.light();
  static final _legacyDark = AutomotiveTheme.dark();

  @override
  Widget build(BuildContext context) {
    // The composition root. Everything below reads its api from here, so the
    // app has one place that decides what a screen talks to.
    return TelemetryScope(
      api: TelemetryApi.shared,
      child: AnimatedBuilder(
        animation: Listenable.merge([
          ThemeController.instance,
          AppExperienceController.instance,
        ]),
        builder: (context, _) {
          final useNewUi = AppExperienceController.instance.newUiEnabled;
          // The v2 journey names one theme out of the catalogue, so it hands
          // MaterialApp that theme alone and pins the mode to it. The legacy
          // journey knows only two, and keeps the light/dark pair.
          final selected = AppTheme.forId(ThemeController.instance.themeId);
          final isDark = ThemeController.instance.isDark;
          return MaterialApp(
            onGenerateTitle: (context) =>
                AppLocalizations.of(context)!.appTitle,
            debugShowCheckedModeBanner: false,
            theme: useNewUi ? selected : _legacyLight,
            darkTheme: useNewUi ? selected : _legacyDark,
            themeMode: useNewUi
                ? (isDark ? ThemeMode.dark : ThemeMode.light)
                : ThemeController.instance.themeMode,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              CapyUiL10n.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: const [
              Locale('pt', 'BR'),
              Locale('pt'),
              Locale('es'),
              Locale('ru'),
              Locale('en'),
            ],
            home: useNewUi ? const AppShellV2() : const AppShell(),
          );
        },
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  String _currentDestinationId = 'trips';

  @override
  void initState() {
    super.initState();
    AppNavigationController.instance.addListener(_onNavigationRequested);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        showExperienceWelcomeDialog(context);
        _onNavigationRequested();
      }
    });
  }

  @override
  void dispose() {
    AppNavigationController.instance.removeListener(_onNavigationRequested);
    super.dispose();
  }

  void _onNavigationRequested() {
    final nav = AppNavigationController.instance;
    final pending = nav.pendingDestination;
    if (pending == null) return;
    // Cleared whether or not this shell knows the destination. A request it
    // cannot serve is spent, not queued: leaving it would open that screen at
    // the next unrelated notification.
    nav.clearPending();
    if (!mounted) return;
    if (_destinations(
      AppLocalizations.of(context)!,
    ).any((destination) => destination.id == pending)) {
      setState(() => _currentDestinationId = pending);
    }
  }

  /// The navigation destinations available in this build. The Trace screen is a
  /// developer tool, so its rail entry is only present in debug builds.
  List<_Destination> _destinations(AppLocalizations loc) {
    final destinations = <_Destination>[
      _Destination(
        id: 'trips',
        icon: Icons.route,
        label: loc.navTrips,
        builder: (_) => const TripSessionsScreen(),
      ),
      _Destination(
        id: 'charging',
        icon: Icons.ev_station,
        label: loc.navCharging,
        builder: (_) => const ChargingSessionsScreen(),
      ),
      _Destination(
        id: 'history',
        icon: Icons.history,
        label: loc.navHistory,
        builder: (_) =>
            kIsWeb ? const HistoryRevampScreen() : const HistoryScreen(),
      ),
      _Destination(
        id: 'roadcast-trace',
        icon: Icons.timeline,
        label: loc.navRoadcastTrace,
        builder: (_) => const RoadcastTraceScreen(),
        debugOnly: true,
      ),
      _Destination(
        id: 'helpers',
        icon: Icons.tune,
        label: loc.navHelpers,
        builder: (_) => const HelpersScreen(),
      ),
      _Destination(
        id: 'settings',
        icon: Icons.settings,
        label: loc.navSettings,
        builder: (_) => const SettingsScreen(),
      ),
    ];
    return destinations
        .where(
          (destination) =>
              kDebugMode ||
              DeveloperToolsGate.instance.unlocked ||
              !destination.debugOnly,
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = AppLocalizations.of(context)!;
    return AnimatedBuilder(
      animation: DeveloperToolsGate.instance,
      builder: (context, _) {
        final destinations = _destinations(loc);
        var index = destinations.indexWhere(
          (destination) => destination.id == _currentDestinationId,
        );
        if (index < 0) index = 0;
        return Scaffold(
          backgroundColor: theme.scaffoldBackgroundColor,
          body: SafeArea(
            child: Row(
              children: [
                _NavRail(
                  destinations: destinations,
                  selectedIndex: index,
                  onSelected: (selected) {
                    HapticFeedback.selectionClick();
                    setState(
                      () => _currentDestinationId = destinations[selected].id,
                    );
                  },
                ),
                Expanded(child: destinations[index].builder(context)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Destination {
  const _Destination({
    required this.id,
    required this.icon,
    required this.label,
    required this.builder,
    this.debugOnly = false,
  });

  final String id;
  final IconData icon;
  final String label;
  final WidgetBuilder builder;
  final bool debugOnly;
}

class _NavRail extends StatelessWidget {
  const _NavRail({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<_Destination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AutomotiveDimensions.navRailWidth,
      color: AutomotiveColors.surfaceContainerLowest,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: AutomotiveColors.outlineVariant),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: AutomotiveSpacing.x1),
            Expanded(
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  children: [
                    for (int i = 0; i < destinations.length; i++)
                      _RailButton(
                        item: destinations[i],
                        active: i == selectedIndex,
                        onTap: () => onSelected(i),
                      ),
                  ],
                ),
              ),
            ),
            Container(
              width: 40,
              height: 40,
              margin: const EdgeInsets.only(bottom: AutomotiveSpacing.x2),
              decoration: BoxDecoration(
                color: AutomotiveColors.surfaceContainerHigh,
                border: Border.all(color: AutomotiveColors.technicalBorder),
                borderRadius: AutomotiveRadii.fullRadius,
              ),
              child: Icon(
                Icons.bolt,
                color: AutomotiveColors.secondary,
                size: 18,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.item,
    required this.active,
    required this.onTap,
  });

  final _Destination item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active
        ? AutomotiveColors.secondary
        : AutomotiveColors.onSurfaceVariant;
    return SizedBox(
      width: double.infinity,
      height: 76,
      child: Material(
        color: active
            ? AutomotiveColors.surfaceContainerHigh
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              if (active)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: SizedBox(
                    width: AutomotiveDimensions.activeRailMarkerWidth,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AutomotiveColors.secondary,
                      ),
                    ),
                  ),
                ),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(item.icon, color: color, size: 28),
                    const SizedBox(height: 5),
                    Text(
                      item.label,
                      style: AutomotiveTextStyles.labelCaps.copyWith(
                        color: color,
                        fontSize: 11,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
