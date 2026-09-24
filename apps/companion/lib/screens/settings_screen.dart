import 'dart:async';

import 'package:capy_ui/capy_ui.dart';
import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../abrp/abrp_settings_store.dart';
import '../abrp/abrp_telemetry_forwarder.dart';
import '../auth/auth_controller.dart';
import '../l10n/app_localizations.dart';
import '../runtime/companion_runtime.dart';
import '../settings/companion_settings_source.dart';
import '../settings/companion_theme_controller.dart';
import '../settings/nominatim_opt_in_store.dart';
import '../sync/preference_control_cloud.dart';
import '../sync/preference_control_sync.dart';
import 'companion_shell.dart';

/// The Settings destination: appearance, external integrations, and account status.
///
/// It draws no `Scaffold`. The shell owns the canvas and the pill row, the
/// same rule the Sync destination follows.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.theme,
    this.auth,
    this.abrpSettings,
    this.abrpForwarder,
    this.nominatimOptIn,
    this.storageSource,
    this.control,
    super.key,
  });

  final CompanionThemeController theme;

  /// Absent when this build carries no account server. The card then says so
  /// rather than offering a sign-out that would refuse.
  final AuthController? auth;

  /// Optional ABRP live stream settings store.
  final AbrpSettingsStore? abrpSettings;

  /// Optional ABRP forwarder instance for live state indication.
  final AbrpTelemetryForwarder? abrpForwarder;

  /// Companion-only Nominatim opt-in store. When null the card still shows
  /// but the toggle is disabled (e.g. in a test without an archive).
  final NominatimOptInStore? nominatimOptIn;

  /// The Lane C control-plane state (issue #227), when this build reaches
  /// the cloud with a signed-in account. Null hides the card: there is no
  /// control plane to draw.
  final PreferenceControlController? control;

  /// Where storage size is read from. In production it is the runtime's
  /// archive source; in a test a fake that answers without a file.
  final HistoricalTelemetrySource? storageSource;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final abrpStore = abrpSettings;
    final nominatimStore = nominatimOptIn;
    final listenables = <Listenable?>[
      theme,
      auth,
      if (abrpStore is Listenable) abrpStore as Listenable,
      if (nominatimStore is Listenable) nominatimStore as Listenable,
      if (control is Listenable) control,
    ].whereType<Listenable>().toList();

    return AnimatedBuilder(
      animation: Listenable.merge(listenables),
      builder: (context, _) {
        final capabilities = SurfaceCapabilities.of(context);
        final cards = <Widget>[
          _AppearanceCard(theme: theme),
          _StorageCard(storageSource: storageSource),
          _NominatimCard(store: nominatimStore),
          if (abrpStore != null)
            _BetaCard(settings: abrpStore, forwarder: abrpForwarder),
          if (control != null) _ControlCard(control: control!),
          _AccountCard(auth: auth),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ScreenTitle(l10n.settingsTitle),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.x6,
                  0,
                  AppSpacing.x6,
                  AppSpacing.x6,
                ),
                children: [
                  SettingsAdaptiveGrid(
                    capabilities: capabilities,
                    children: cards,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AppearanceCard extends StatefulWidget {
  const _AppearanceCard({required this.theme});

  final CompanionThemeController theme;

  @override
  State<_AppearanceCard> createState() => _AppearanceCardState();
}

class _AppearanceCardState extends State<_AppearanceCard> {
  late final CompanionSettingsSource _source = CompanionSettingsSource(
    widget.theme,
  );
  late final SettingsBodyController _controller = SettingsBodyController(
    source: _source,
  );

  @override
  void dispose() {
    _controller.dispose();
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AppCard(
      key: const Key('settings-appearance'),
      title: l10n.settingsAppearance,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => SettingsBody(
          themeId: _controller.themeId,
          onThemeChanged: _controller.setThemeId,
          reduceMotion: _controller.reduceMotion,
          onReduceMotionChanged: _controller.setReduceMotion,
          capabilities: SurfaceCapabilities.of(context),
        ),
      ),
    );
  }
}

/// The Beta section: features still under test.
///
/// The ABRP switch is the gate for the whole live stream. While it is off the
/// app opens no radio and asks for no Bluetooth permission, so a driver who
/// does not want the feature is never prompted for it.
class _BetaCard extends StatefulWidget {
  const _BetaCard({required this.settings, this.forwarder});

  final AbrpSettingsStore settings;
  final AbrpTelemetryForwarder? forwarder;

  @override
  State<_BetaCard> createState() => _BetaCardState();
}

class _BetaCardState extends State<_BetaCard> {
  late final TextEditingController _tokenController;
  late final TextEditingController _apiKeyController;

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController(
      text: widget.settings.userToken ?? '',
    );
    _apiKeyController = TextEditingController(
      text: widget.settings.apiKey ?? '',
    );
  }

  @override
  void didUpdateWidget(covariant _BetaCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.userToken != widget.settings.userToken &&
        _tokenController.text != (widget.settings.userToken ?? '')) {
      _tokenController.text = widget.settings.userToken ?? '';
    }
    if (oldWidget.settings.apiKey != widget.settings.apiKey &&
        _apiKeyController.text != (widget.settings.apiKey ?? '')) {
      _apiKeyController.text = widget.settings.apiKey ?? '';
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  /// Opens the address in the browser, and says the address out loud when no
  /// browser takes it. A tap that silently does nothing leaves the reader with
  /// no way to reach the page at all.
  Future<void> _openLink(String url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = AppLocalizations.of(context)!;
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (opened || !mounted) return;
    messenger?.showSnackBar(
      SnackBar(content: Text(l10n.settingsAbrpHelpLinkFailed(url))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final forwarder = widget.forwarder;
    final enabled = widget.settings.enabled;

    return AppCard(
      key: const Key('settings-beta'),
      title: l10n.settingsBeta,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.settingsBetaDesc,
            style: AppText.caption.copyWith(color: colors.inkMuted),
          ),
          const SizedBox(height: AppSpacing.x4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: SettingToggleRow(
                  key: const Key('settings-abrp-toggle'),
                  label: l10n.settingsBetaAbrpSync,
                  description: l10n.settingsBetaAbrpSyncDesc,
                  value: enabled,
                  onChanged: widget.settings.setEnabled,
                ),
              ),
              const SizedBox(width: AppSpacing.x2),
              // The whole toggle row is already one tap target, so the help
              // sits beside it rather than inside it. Two targets in one row
              // would make the switch ambiguous to reach.
              AnchoredTooltipTrigger(
                key: const Key('settings-abrp-info'),
                side: AnchoredTooltipSide.left,
                anchorInsets: const EdgeInsets.all(AppSpacing.x2),
                barrierLabel: l10n.settingsAbrpHelpClose,
                tooltipBuilder: (context) => InformationTooltipPanel(
                  title: l10n.settingsAbrpHelpTitle,
                  children: [
                    InformationCard(
                      icon: Icons.vpn_key,
                      value: l10n.settingsAbrpHelpApiKeyTitle,
                      description: l10n.settingsAbrpHelpApiKeySteps,
                      linkLabel: l10n.settingsAbrpHelpApiKeyLink,
                      onLinkPressed: () =>
                          _openLink(l10n.settingsAbrpHelpApiKeyLink),
                    ),
                    InformationCard(
                      icon: Icons.directions_car,
                      value: l10n.settingsAbrpHelpTokenTitle,
                      description: l10n.settingsAbrpHelpTokenSteps,
                    ),
                  ],
                ),
                builder: (context, isOpen, open) => InfoIconButton(
                  selected: isOpen,
                  tooltip: l10n.settingsAbrpHelpTitle,
                  onPressed: open,
                ),
              ),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: AppSpacing.x4),
            TextField(
              key: const Key('settings-abrp-token-input'),
              controller: _tokenController,
              decoration: InputDecoration(
                labelText: l10n.settingsAbrpTokenLabel,
                hintText: l10n.settingsAbrpTokenHint,
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => widget.settings.setUserToken(value.trim()),
            ),
            const SizedBox(height: AppSpacing.x2),
            Text(
              l10n.settingsAbrpTokenHelp,
              style: AppText.caption.copyWith(color: colors.inkMuted),
            ),
            const SizedBox(height: AppSpacing.x4),
            TextField(
              key: const Key('settings-abrp-api-key-input'),
              controller: _apiKeyController,
              decoration: InputDecoration(
                labelText: l10n.settingsAbrpApiKeyLabel,
                hintText: l10n.settingsAbrpApiKeyHint,
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => widget.settings.setApiKey(value),
            ),
            const SizedBox(height: AppSpacing.x2),
            Text(
              l10n.settingsAbrpApiKeyHelp,
              style: AppText.caption.copyWith(color: colors.inkMuted),
            ),
            if (forwarder != null) ...[
              const SizedBox(height: AppSpacing.x3),
              AnimatedBuilder(
                animation: forwarder,
                builder: (context, _) {
                  final status = forwarder.status;
                  final text = switch (status.state) {
                    AbrpForwarderState.streaming =>
                      l10n.settingsAbrpStateStreaming,
                    AbrpForwarderState.idle => l10n.settingsAbrpStateIdle,
                    AbrpForwarderState.error => l10n.settingsAbrpStateError(
                      status.lastError ?? '',
                    ),
                    AbrpForwarderState.disabled =>
                      l10n.settingsAbrpStateDisabled,
                  };
                  final color = switch (status.state) {
                    AbrpForwarderState.streaming => colors.energy.gain,
                    AbrpForwarderState.error => colors.energy.critical,
                    _ => colors.inkMuted,
                  };
                  return Text(
                    text,
                    style: AppText.caption.copyWith(color: color),
                  );
                },
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _NominatimCard extends StatelessWidget {
  const _NominatimCard({this.store});

  final NominatimOptInStore? store;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final enabled = store?.enabled ?? false;

    return AppCard(
      key: const Key('settings-nominatim'),
      title: l10n.settingsNominatimTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingToggleRow(
            key: const Key('settings-nominatim-toggle'),
            label: l10n.settingsNominatimOptIn,
            description: l10n.settingsNominatimOptInDesc,
            value: enabled,
            onChanged: store == null ? null : (v) => store!.setEnabled(v),
          ),
          const SizedBox(height: AppSpacing.x3),
          Text(
            l10n.settingsNominatimAttribution,
            style: AppText.caption.copyWith(color: colors.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.auth});

  final AuthController? auth;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final controller = auth;
    final session = controller?.session;

    final Widget body;
    if (controller == null) {
      body = Text(
        l10n.settingsNoAccountServer,
        style: AppText.body.copyWith(color: colors.inkMuted),
      );
    } else if (session == null) {
      body = Text(
        l10n.settingsSignedOut,
        style: AppText.body.copyWith(color: colors.inkMuted),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.settingsSignedInAs(session.email),
            style: AppText.body.copyWith(color: colors.ink),
          ),
          const SizedBox(height: AppSpacing.x4),
          SoftActionTile(
            key: const Key('settings-sign-out'),
            label: l10n.settingsSignOut,
            icon: Icons.logout,
            onPressed: controller.busy ? null : controller.signOut,
          ),
        ],
      );
    }

    return AppCard(
      key: const Key('settings-account'),
      title: l10n.settingsAccount,
      child: body,
    );
  }
}

class _StorageCard extends StatefulWidget {
  const _StorageCard({this.storageSource});

  final HistoricalTelemetrySource? storageSource;

  @override
  State<_StorageCard> createState() => _StorageCardState();
}

class _StorageCardState extends State<_StorageCard> {
  HistoricalTelemetrySource? _source;
  StorageUsage? _usage;
  bool _loading = true;
  String? _error;
  StreamSubscription<SessionChange>? _sub;

  @override
  void initState() {
    super.initState();
    _source =
        widget.storageSource ?? CompanionRuntime.instance.maybeServices?.source;
    _load();
    _sub = _source?.sessionChanges().listen((_) => _load());
  }

  @override
  void didUpdateWidget(covariant _StorageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storageSource != widget.storageSource) {
      _sub?.cancel();
      _source =
          widget.storageSource ??
          CompanionRuntime.instance.maybeServices?.source;
      _load();
      _sub = _source?.sessionChanges().listen((_) => _load());
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final source = _source;
    if (source == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final usage = await source.storageUsage();
      if (!mounted) return;
      setState(() {
        _usage = usage;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final usage = _usage;
    final String label;
    if (_loading) {
      label = l10n.settingsStorageLoading;
    } else if (_error != null) {
      label = l10n.settingsStorageFailed(_error!);
    } else if (usage == null) {
      label = l10n.settingsStorageLoading;
    } else {
      // Locale-aware, so pt-BR sees 3,66 MB, not 3.66 MB.
      // ignore: use_build_context_synchronously
      final locale = Localizations.localeOf(context).languageCode;
      label = l10n.settingsStorageValue(
        formatStorageBytes(usage.bytes, locale: locale),
      );
    }
    return AppCard(
      key: const Key('settings-storage'),
      title: l10n.settingsStorageTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.settingsStorageDesc,
            style: AppText.caption.copyWith(
              color: AppThemeColors.of(context).inkMuted,
            ),
          ),
          const SizedBox(height: AppSpacing.x3),
          SoftActionTile(
            key: const Key('settings-storage-tile'),
            icon: Icons.storage,
            label: label,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
    );
  }
}

/// Lane C control card (issue #227): what the phone wants for the car's
/// control keys and the status the cloud view derives for each.
///
/// Every status shown here comes from the `preference_control_status` view —
/// never from what this phone just sent. Proposing writes a
/// `preference_desired` row and then re-reads the view, so a proposal that the
/// car has not answered yet reads `pending`, and nothing here claims a value
/// took effect before the car reported it.
class _ControlCard extends StatefulWidget {
  const _ControlCard({required this.control});

  final PreferenceControlController control;

  @override
  State<_ControlCard> createState() => _ControlCardState();
}

class _ControlCardState extends State<_ControlCard> {
  bool _busy = false;
  bool _refreshing = false;

  PreferenceControlController get _control => widget.control;

  @override
  void initState() {
    super.initState();
    // The card is only drawn when a control plane exists, so an empty list
    // would be a claim the phone asked nothing — it simply has not read yet.
    // One read on open shows the confirmed state, never assumed state.
    if (_control.rows == null) {
      unawaited(_control.refresh().catchError((Object _) => 0));
    }
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      await _control.refresh();
    } catch (_) {
      // The card body draws lastError below.
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _propose(String key) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_keyLabel(l10n, key)),
        content: TextField(
          key: const Key('control-propose-input'),
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: l10n.controlProposeFieldHint,
            hintText: l10n.controlProposeFieldHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.controlProposeCancel),
          ),
          TextButton(
            key: const Key('control-propose-send'),
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(l10n.controlProposeSend),
          ),
        ],
      ),
    );
    if (value == null || !mounted) return;

    setState(() => _busy = true);
    _clearStatus();
    try {
      final result = await _control.propose(key: key, value: value);
      if (!mounted) return;
      if (!result.wrote) {
        _reportStatus(_refusalLabel(l10n, result.refusal));
        return;
      }
      final status = result.row?.status;
      _reportStatus(
        status == null
            ? l10n.controlProposedStatusUnknown
            : l10n.controlProposedStatus(_statusLabel(l10n, status)),
      );
    } catch (error) {
      if (!mounted) return;
      _reportStatus(l10n.controlLastError('$error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _refusalLabel(AppLocalizations l10n, ProposalRefusal? refusal) {
    return switch (refusal) {
      ProposalRefusal.unconfigured => l10n.controlUnconfigured,
      ProposalRefusal.unknownVehicle => l10n.controlNoVehicle,
      null => l10n.controlNoRows,
    };
  }

  void _clearStatus() => _statusMessage = null;
  void _reportStatus(String message) => _statusMessage = message;
  String? _statusMessage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final control = _control;

    final Widget body;
    if (!control.isConfigured) {
      body = Text(
        l10n.controlUnconfigured,
        style: AppText.body.copyWith(color: colors.inkMuted),
      );
    } else if (control.vehicleId == null && control.rows?.isEmpty != false) {
      body = Text(
        l10n.controlNoVehicle,
        style: AppText.body.copyWith(color: colors.inkMuted),
      );
    } else {
      final rows = <Widget>[];
      for (final key in kControlPreferenceKeys) {
        final row = control.rowFor(key);
        rows.add(
          SettingsEntry(
            title: _keyLabel(l10n, key),
            description: row == null
                ? l10n.controlNoRowsForKey
                : _rowDescription(l10n, row, colors),
            child: SoftActionTile(
              icon: Icons.tune,
              label: _busy ? l10n.controlProposing : l10n.controlProposeAction,
              onPressed: _busy ? null : () => _propose(key),
            ),
          ),
        );
      }
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...rows,
          if (_control.lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.x2),
              child: Text(
                l10n.controlLastError('${_control.lastError}'),
                style: AppText.caption.copyWith(color: colors.energy.critical),
              ),
            ),
        ],
      );
    }

    return AppCard(
      key: const Key('settings-control'),
      title: l10n.controlCardTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.controlCardDesc,
            style: AppText.caption.copyWith(color: colors.inkMuted),
          ),
          const SizedBox(height: AppSpacing.x3),
          body,
          if (_statusMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.x2),
              child: Text(
                _statusMessage!,
                style: AppText.body.copyWith(color: colors.energy.gain),
              ),
            ),
          const SizedBox(height: AppSpacing.x3),
          SoftActionTile(
            key: const Key('settings-control-refresh'),
            icon: Icons.refresh,
            label: _refreshing ? l10n.controlRefreshing : l10n.controlRefresh,
            onPressed: _refreshing ? null : _refresh,
          ),
        ],
      ),
    );
  }

  String _rowDescription(
    AppLocalizations l10n,
    PreferenceControlStatusRow row,
    AppThemeColors colors,
  ) {
    final status = _statusLabel(l10n, row.status);
    final desired = row.desiredValue ?? l10n.controlValueMissing;
    final reported = row.reportedValue ?? l10n.controlValueMissing;
    return '$status · '
        '${l10n.controlDesiredLabel} $desired · '
        '${l10n.controlReportedLabel} $reported';
  }

  String _statusLabel(AppLocalizations l10n, PreferenceControlStatus status) {
    return switch (status) {
      PreferenceControlStatus.pending => l10n.controlStatusPending,
      PreferenceControlStatus.confirmed => l10n.controlStatusConfirmed,
      PreferenceControlStatus.stale => l10n.controlStatusStale,
      PreferenceControlStatus.refused => l10n.controlStatusRefused,
      PreferenceControlStatus.reportedOnly => l10n.controlStatusReportedOnly,
    };
  }

  String _keyLabel(AppLocalizations l10n, String key) {
    return switch (key) {
      'pack_capacity_wh' => l10n.controlKeyPackCapacity,
      'default_charge_cost_per_kwh' => l10n.controlKeyChargeCost,
      _ => key,
    };
  }
}
