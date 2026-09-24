import 'dart:async';

import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'abrp/abrp_settings_store.dart';
import 'abrp/abrp_telemetry_forwarder.dart';
import 'auth/auth_controller.dart';
import 'auth/supabase_account_gateway.dart';
import 'ble/live_telemetry_ble_client.dart';
import 'l10n/app_localizations.dart';
import 'onboarding/onboarding_flow.dart';
import 'onboarding/onboarding_store.dart';
import 'runtime/companion_runtime.dart';
import 'settings/companion_theme_controller.dart';
import 'sync/cloud_migration.dart';
import 'screens/companion_shell.dart';
import 'screens/home_screen.dart';
import 'package:telemetry_core/telemetry_core.dart';

import 'settings/nominatim_opt_in_store.dart';
import 'sync/journey_store.dart';
import 'sync/pairing_controller.dart';
import 'sync/preference_control_sync.dart';
import 'sync/sync_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final (services, gateway) = await (
    CompanionRuntime.instance.start(),
    SupabaseAccountGateway.start(),
  ).wait;
  // Null when this build carries no project. The journey then skips the
  // account step whole rather than drawing a form every press would refuse.
  final auth = gateway == null ? null : (AuthController(gateway)..restore());
  // Fresh install with a live session: the local file is gone but the cloud
  // still names this account's car. Restore it so the pairing screen is
  // skipped. Not awaited: offline never blocks the first frame.
  if (auth != null && auth.isSignedIn) {
    unawaited(services.pairingController.restore());
  }
  final theme = CompanionThemeController(services.archive);
  await theme.load();
  final sync = SyncController(car: CompanionRuntime.instance);
  // Additive beside the manual "Sincronizar" button: pulls from the cloud
  // every few minutes and on app resume, so new trips appear without a tap.
  sync.startAutoSync();
  // Not awaited: counts refresh in the background without holding the first frame.
  unawaited(sync.refreshCounts());
  runApp(
    CompanionApp.fromServices(
      services: services,
      auth: auth,
      theme: theme,
      sync: sync,
    ),
  );
}

/// Phone companion. A separate Flutter app, not a platform fork of the car
/// target.
class CompanionApp extends StatefulWidget {
  const CompanionApp({
    required this.pairing,
    this.theme,
    this.auth,
    this.sync,
    this.ble,
    this.abrpSettings,
    this.abrpForwarder,
    this.nominatimOptIn,
    this.source,
    this.store,
    this.journeys,
    this.onboarding,
    this.control,
    this.cloudMigration,
    this.locale,
    super.key,
  });

  /// Production entry point: one non-nullable value, so "not started" is not
  /// representable downstream. Tests keep the default constructor with
  /// optional fields.
  CompanionApp.fromServices({
    required CompanionServices services,
    this.theme,
    this.auth,
    this.sync,
    this.locale,
    super.key,
  }) : pairing = services.pairingController,
       ble = services.ble,
       abrpSettings = services.abrpSettings,
       abrpForwarder = services.abrpForwarder,
       nominatimOptIn = services.nominatimOptIn,
       source = services.source,
       store = services.store,
       journeys = services.journeys,
       onboarding = services.onboarding,
       control = services.control,
       cloudMigration = services.cloudMigration;

  /// Test override. Production follows the device locale.
  final Locale? locale;

  final PairingController pairing;

  /// Optional BLE live telemetry client.
  final LiveTelemetryBleClient? ble;

  /// Optional ABRP settings store.
  final AbrpSettingsStore? abrpSettings;

  /// Optional ABRP telemetry forwarder.
  final AbrpTelemetryForwarder? abrpForwarder;

  final NominatimOptInStore? nominatimOptIn;

  /// What the app is drawn with. Absent in a test that does not care, and the
  /// app then holds one of its own so the picker still works.
  final CompanionThemeController? theme;

  /// The account form. Absent when this build carries no account server.
  final AuthController? auth;

  /// Absent in a test that only exercises pairing.
  final SyncController? sync;

  /// The local archive to read history from. Absent until the runtime is up.
  final HistoricalTelemetrySource? source;

  /// The phone's read surface. Absent until the runtime is up, the same as
  /// [source], and the shell is not drawn without both.
  final TelemetryStore? store;

  final JourneyStore? journeys;

  /// The Lane C control-plane state (issue #227), when this build reaches
  /// the cloud with a signed-in account.
  final PreferenceControlController? control;

  /// One-time migration (Phase 4 Step 2).
  final CloudMigration? cloudMigration;

  /// The first-run flag. Absent until the runtime is up, and absent in a test
  /// that exercises a later surface: no store, no journey. A screen cannot
  /// state that a reader has been through something nothing recorded.
  final OnboardingStore? onboarding;

  @override
  State<CompanionApp> createState() => _CompanionAppState();
}

class _CompanionAppState extends State<CompanionApp> {
  /// Whether the first-run journey is still in front of the app. Read once,
  /// so that marking the flag does not have to race a rebuild.
  late bool _introPending = widget.onboarding?.seen == false;

  late final CompanionThemeController _theme =
      widget.theme ?? CompanionThemeController(null);

  /// When the last sync run this app saw finished.
  ///
  /// The theme syncs both ways, so a choice made on the car reaches this
  /// phone as a `theme_id` row in the pull. Re-reading it after a run is what
  /// makes that direction real; without it the row would land in the archive
  /// and change nothing until the next start.
  DateTime? _seenRunAt;

  @override
  void initState() {
    super.initState();
    widget.sync?.addListener(_onSyncChanged);
    widget.auth?.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.sync?.removeListener(_onSyncChanged);
    widget.auth?.removeListener(_onAuthChanged);
    super.dispose();
  }

  /// Signing out is leaving, not a setting.
  ///
  /// A build with an account server does not let a reader past the account, so
  /// a reader who signed out is outside it again and the app must show the
  /// door rather than the rooms behind it. Rebuilding is enough: [build]
  /// decides from the session, so there is one rule and not a second copy of
  /// it in a navigation call.
  void _onAuthChanged() => setState(() {});

  void _onSyncChanged() {
    final finishedAt = widget.sync?.lastRunAt;
    if (finishedAt == null || finishedAt == _seenRunAt) return;
    _seenRunAt = finishedAt;
    unawaited(_theme.load());
    unawaited(widget.nominatimOptIn?.load());
  }

  Future<void> _finishIntro() async {
    await widget.onboarding?.markSeen();
    if (!mounted) return;
    setState(() => _introPending = false);
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final store = widget.store;
    return ListenableBuilder(
      listenable: _theme,
      builder: (context, _) => _app(source, store),
    );
  }

  /// Whether this build has an account and nobody is in it.
  ///
  /// A build with no account server never shows the door: there is nothing to
  /// be signed out of.
  bool get _signedOut {
    final auth = widget.auth;
    return auth != null && !auth.isSignedIn;
  }

  /// The reader signed back in. The shell returns on the next build, which the
  /// controller's own notification already asked for.
  void _onSignedBackIn() {
    if (mounted) setState(() {});
  }

  Widget _app(HistoricalTelemetrySource? source, TelemetryStore? store) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      debugShowCheckedModeBanner: false,
      locale: widget.locale,
      // One theme, both slots. The catalogue's brightness is the mode, so a
      // reader who picked `midnight` gets midnight whatever the phone's own
      // day/night setting says.
      theme: AppTheme.forId(_theme.themeId),
      darkTheme: AppTheme.forId(_theme.themeId),
      themeMode: _theme.themeMode,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        CapyUiL10n.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: _introPending
          ? OnboardingFlow(
              pairing: widget.pairing,
              auth: widget.auth,
              sync: widget.sync,
              onFinished: _finishIntro,
            )
          : _signedOut
          // The account door, not the journey: the slides were seen and the
          // car is still paired.
          ? OnboardingFlow(
              key: const Key('account-door'),
              pairing: widget.pairing,
              auth: widget.auth,
              sync: widget.sync,
              accountOnly: true,
              onFinished: _onSignedBackIn,
            )
          : source == null || store == null
          // No store, no history tab: a shell with one destination is a
          // screen, and drawing an empty tab beside it would offer a place
          // that cannot answer.
          // The screen draws no Scaffold of its own: in the shell it is one
          // destination among five. Alone, it needs the canvas the shell
          // would have given it.
          ? Scaffold(
              backgroundColor: AppThemeColors.of(context).canvas,
              body: SafeArea(
                child: HomeScreen(
                  pairing: widget.pairing,
                  sync: widget.sync,
                  ble: widget.ble,
                  abrpForwarder: widget.abrpForwarder,
                  cloudMigration: widget.cloudMigration,
                ),
              ),
            )
          : CompanionShell(
              pairing: widget.pairing,
              sync: widget.sync,
              ble: widget.ble,
              abrpSettings: widget.abrpSettings,
              abrpForwarder: widget.abrpForwarder,
              nominatimOptIn: widget.nominatimOptIn,
              control: widget.control,
              cloudMigration: widget.cloudMigration,
              source: source,
              store: store,
              journeys: widget.journeys,
              theme: _theme,
              auth: widget.auth,
            ),
    );
  }
}
