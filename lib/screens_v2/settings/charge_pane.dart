import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/telemetry_api.dart';
import '../../core/telemetry_scope.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import 'settings_pane.dart';

/// Charge: external charge control, OEM charging replacement, pack capacity,
/// and charge cost configuration.
class ChargePane extends StatefulWidget {
  const ChargePane({this.telemetryApi, super.key});

  /// Seam for tests. Production passes nothing and gets the real channel.
  final TelemetryApi? telemetryApi;

  @override
  State<ChargePane> createState() => _ChargePaneState();
}

class _ChargePaneState extends State<ChargePane>
    with SettingsPaneState<ChargePane> {
  late final TelemetryApi _api =
      widget.telemetryApi ?? TelemetryScope.of(context);

  bool? _replaceOemChargingEnabled;
  bool? _externalChargeControlEnabled;
  ChargeControlAppStatus? _chargeControlAppStatus;
  bool _installingChargeControl = false;
  double? _downloadProgress;
  StreamSubscription<double>? _downloadProgressSub;
  Timer? _statusCheckTimer;

  /// The price the app uses when a charge carries none of its own. Null means
  /// no default is saved, which is a real state and not a zero price.
  double? _defaultChargeCostPerKwh;
  String _chargeCostCurrency = 'BRL';
  bool _savingChargeCost = false;
  bool _applyingChargeCost = false;

  /// The pack every energy figure is computed against. Never null: the car
  /// reports none that can be believed, so an unset setting is the default
  /// pack rather than an unknown one.
  double _packCapacityWh = kDefaultPackCapacityWh;
  bool _savingCapacity = false;

  /// Proposals a phone made for the car-only keys.
  List<PreferenceProposal> _proposals = const [];
  bool _decidingProposal = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadProposals();
  }

  @override
  void dispose() {
    _downloadProgressSub?.cancel();
    _statusCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadProposals() async {
    try {
      final proposals = await _api.getPreferenceProposals();
      if (mounted) setState(() => _proposals = proposals);
    } catch (_) {
      // A phone that cannot be reached changes nothing on this screen.
    }
  }

  Future<void> _decideProposal({
    required PreferenceProposal proposal,
    required bool accept,
  }) async {
    setState(() => _decidingProposal = true);
    try {
      await _api.decidePreferenceProposal(id: proposal.id, accept: accept);
      if (mounted) {
        setState(() {
          _proposals = [
            for (final p in _proposals)
              if (p.id != proposal.id) p,
          ];
        });
        if (accept) {
          await _loadSettings();
          await _loadProposals();
        }
      }
      HapticFeedback.selectionClick();
    } finally {
      if (mounted) setState(() => _decidingProposal = false);
    }
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _api.getTelemetrySettings();
      if (!mounted) return;
      setState(() {
        _replaceOemChargingEnabled = settings.replaceOemChargingEnabled;
        _externalChargeControlEnabled = settings.externalChargeControlEnabled;
        _defaultChargeCostPerKwh = settings.defaultChargeCostPerKwh;
        _chargeCostCurrency = settings.chargeCostCurrency;
        _packCapacityWh = settings.packCapacityWh;
      });
      if (settings.externalChargeControlEnabled) {
        _loadChargeControlAppStatus();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _replaceOemChargingEnabled = null;
          _externalChargeControlEnabled = null;
        });
      }
    }
  }

  Future<void> _loadChargeControlAppStatus() async {
    try {
      final status = await _api.getChargeControlAppStatus();
      if (!mounted) return;
      setState(() {
        _chargeControlAppStatus = status;
      });
    } catch (_) {
      // Ignored: status remains null or previous
    }
  }

  Future<void> _installChargeControlApp() async {
    final loc = AppLocalizations.of(context)!;
    clearStatus();
    setState(() {
      _installingChargeControl = true;
      _downloadProgress = 0.0;
    });
    _downloadProgressSub?.cancel();
    _downloadProgressSub = _api.chargeControlDownloadProgress().listen((
      progress,
    ) {
      if (mounted) {
        setState(() => _downloadProgress = progress);
      }
    });
    try {
      final status = await _api.installChargeControlApp();
      if (!mounted) return;
      setState(() {
        _chargeControlAppStatus = status;
        _installingChargeControl = false;
        _downloadProgress = null;
      });
      if (status.error != null && !status.installed) {
        reportError(status.error!);
      } else {
        reportOk(loc.settingsChargeControlInstalledSuccess);
      }
      await _loadChargeControlAppStatus();
      _statusCheckTimer?.cancel();
      _statusCheckTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) _loadChargeControlAppStatus();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _installingChargeControl = false;
        _downloadProgress = null;
      });
      reportError('$e');
      await _loadChargeControlAppStatus();
    } finally {
      _downloadProgressSub?.cancel();
      _downloadProgressSub = null;
    }
  }

  Future<void> _launchChargeControlApp() async {
    final loc = AppLocalizations.of(context)!;
    try {
      final ok = await _api.launchChargeControlApp();
      if (!ok && mounted) {
        reportError(loc.settingsChargeControlLaunchFailed);
      }
    } catch (e) {
      if (mounted) reportError('$e');
    }
  }

  Future<void> _applySwitch({
    required bool requested,
    required bool? previous,
    required Future<TelemetrySettingsResult> Function(bool) write,
    required bool Function(TelemetrySettingsResult) read,
    required void Function(bool?) assign,
    required String Function(Object error) describeError,
  }) async {
    setState(() {
      assign(requested);
      clearStatus();
    });
    try {
      final settings = await write(requested);
      if (!mounted) return;
      setState(() => assign(read(settings)));
      HapticFeedback.selectionClick();
    } catch (error) {
      if (!mounted) return;
      setState(() => assign(previous));
      reportError(describeError(error));
    }
  }

  static bool _readReplaceOemCharging(TelemetrySettingsResult settings) =>
      settings.replaceOemChargingEnabled;
  static bool _readExternalChargeControl(TelemetrySettingsResult settings) =>
      settings.externalChargeControlEnabled;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSections(
          children: [
            _batteryCard(loc),
            _disclaimerCard(loc),
            _chargeControlCard(loc),
          ],
        ),
        SettingsStatusLine(status: status),
      ],
    );
  }

  Widget _disclaimerCard(AppLocalizations loc) {
    final colors = AppThemeColors.of(context);
    return AppCard(
      title: loc.settingsChargeDisclaimerTitle,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: colors.energy.warning,
            size: AppSizes.iconLg,
          ),
          const SizedBox(width: AppSpacing.x3),
          Expanded(
            child: Text(
              loc.settingsChargeDisclaimerDesc,
              style: AppText.body.copyWith(color: colors.inkMuted, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chargeControlCard(AppLocalizations loc) {
    final colors = AppThemeColors.of(context);
    return AppCard(
      title: loc.v2SettingsCharge,
      child: SettingsRows(
        children: [
          SettingToggleRow(
            label: loc.settingsExternalChargeControlTitle,
            description: loc.settingsExternalChargeControlDesc,
            value: _externalChargeControlEnabled ?? false,
            onChanged: _externalChargeControlEnabled == null
                ? null
                : (enabled) => _applySwitch(
                    requested: enabled,
                    previous: _externalChargeControlEnabled,
                    write: _api.setExternalChargeControlEnabled,
                    read: _readExternalChargeControl,
                    assign: (value) {
                      _externalChargeControlEnabled = value;
                      if (value == true) _loadChargeControlAppStatus();
                    },
                    describeError: (error) => '$error',
                  ),
          ),
          if (_externalChargeControlEnabled == true)
            SettingsEntry(
              title: _chargeControlAppStatus?.installed == true
                  ? loc.settingsChargeControlInstalled(
                      _chargeControlAppStatus?.installedVersionName ?? '1.0.0',
                    )
                  : loc.settingsChargeControlNotInstalled,
              description: _chargeControlAppStatus?.installed == true
                  ? 'Geely Charge Control está pronto para executar operações de recarga.'
                  : 'Baixe e instale o APK para habilitar a manipulação de recarga.',
              child: _chargeControlAppStatus?.installed == true
                  ? SoftActionTile(
                      icon: Icons.launch,
                      label: loc.settingsChargeControlOpenApp,
                      onPressed: _launchChargeControlApp,
                    )
                  : _installingChargeControl
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SoftActionTile(
                          icon:
                              _downloadProgress != null &&
                                  _downloadProgress! < 1.0
                              ? Icons.downloading
                              : Icons.download,
                          label: _downloadProgress != null
                              ? loc.settingsChargeControlDownloadingPercent(
                                  (_downloadProgress! * 100).round().clamp(
                                    0,
                                    100,
                                  ),
                                )
                              : loc.settingsChargeControlInstalling,
                          onPressed: null,
                        ),
                        if (_downloadProgress != null) ...[
                          const SizedBox(height: AppSpacing.x2),
                          ClipRRect(
                            borderRadius: AppRadii.xsRadius,
                            child: LinearProgressIndicator(
                              value: _downloadProgress,
                              minHeight: 4,
                              backgroundColor: colors.control,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                colors.energy.gain,
                              ),
                            ),
                          ),
                        ],
                      ],
                    )
                  : SoftActionTile(
                      icon: Icons.download,
                      label: loc.settingsChargeControlDownloadAndInstall,
                      onPressed: _installChargeControlApp,
                    ),
            ),
          SettingToggleRow(
            label: loc.settingsReplaceOemChargingTitle,
            description: loc.settingsReplaceOemChargingDesc,
            value: _replaceOemChargingEnabled ?? false,
            onChanged: _replaceOemChargingEnabled == null
                ? null
                : (enabled) => _applySwitch(
                    requested: enabled,
                    previous: _replaceOemChargingEnabled,
                    write: _api.setReplaceOemChargingEnabled,
                    read: _readReplaceOemCharging,
                    assign: (value) => _replaceOemChargingEnabled = value,
                    describeError: (error) => '$error',
                  ),
          ),
        ],
      ),
    );
  }

  Widget _batteryCard(AppLocalizations loc) {
    return AppCard(
      title: loc.settingsPackCapacityTitle,
      child: SettingsRows(
        children: [
          SettingsEntry(
            title: loc.settingsPackCapacityTitle,
            description: loc.settingsPackCapacityDesc,
            child: _packCapacityTile(loc),
          ),
          SettingsEntry(
            title: loc.settingsChargeCostTitle,
            description: loc.settingsChargeCostDesc,
            child: _chargeCostTile(loc),
          ),
          SettingsEntry(
            title: loc.settingsChargeCostApplyTitle,
            description: loc.settingsChargeCostApplyDesc,
            child: SoftActionTile(
              icon: Icons.price_check,
              label: _applyingChargeCost
                  ? loc.settingsChargeCostApplying
                  : loc.settingsChargeCostApply,
              onPressed: _applyingChargeCost || _defaultChargeCostPerKwh == null
                  ? null
                  : _applyDefaultChargeCost,
            ),
          ),
          if (_proposals.isNotEmpty) ..._proposalTiles(loc),
        ],
      ),
    );
  }

  List<Widget> _proposalTiles(AppLocalizations loc) {
    final proposals = _proposals;
    return [
      for (final proposal in proposals)
        SettingsEntry(
          title: _proposalTitle(loc, proposal.key),
          description: _proposalDescription(proposal),
          child: AnchoredTooltipTrigger(
            side: AnchoredTooltipSide.left,
            barrierLabel: loc.v2MoneyKeypadClose,
            tooltipBuilder: (context) => DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainer,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                borderRadius: AppRadii.mdRadius,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(loc.settingsProposalPrompt, style: AppText.body),
                  Row(
                    children: [
                      _ProposalButton(
                        label: loc.settingsProposalRefuse,
                        onTap: () =>
                            _decideProposal(proposal: proposal, accept: false),
                      ),
                      _ProposalButton(
                        label: loc.settingsProposalAccept,
                        onTap: () =>
                            _decideProposal(proposal: proposal, accept: true),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            builder: (context, isOpen, open) => SoftActionTile(
              icon: Icons.lightbulb,
              label: _decidingProposal
                  ? loc.settingsProposalDeciding
                  : loc.settingsProposalDecision,
              selected: isOpen,
              onPressed: _decidingProposal ? null : open,
            ),
          ),
        ),
    ];
  }

  String _proposalTitle(AppLocalizations loc, String key) => switch (key) {
    'pack_capacity_wh' => loc.settingsPackCapacityTitle,
    'default_charge_cost_per_kwh' => loc.settingsChargeCostTitle,
    _ => loc.settingsProposalUnknown,
  };

  String _proposalDescription(PreferenceProposal proposal) {
    final value = proposal.value ?? '--';
    return proposal.key == 'pack_capacity_wh' ? '$value Wh' : '$value /kWh';
  }

  Widget _packCapacityTile(AppLocalizations loc) {
    final separator = chargeDecimalSeparatorForLocale(loc.localeName);
    return AnchoredTooltipTrigger(
      side: AnchoredTooltipSide.left,
      barrierLabel: loc.v2MoneyKeypadClose,
      tooltipBuilder: (context) => MoneyKeypadDialog<String>(
        fields: [
          MoneyKeypadField(
            value: 'capacity',
            label: loc.settingsPackCapacityTitle,
            amount: _packCapacityWh / 1000,
            unit: loc.unitKwh,
          ),
        ],
        currencySymbol: '',
        decimalSeparator: separator,
        title: loc.settingsPackCapacityTitle,
        description: loc.settingsPackCapacityDesc,
        saveLabel: loc.v2MoneyKeypadSave,
        clearLabel: loc.v2MoneyKeypadClear,
        deleteLabel: loc.v2MoneyKeypadDelete,
        onSubmitted: (result) => _savePackCapacity(
          result.amount == null ? null : result.amount! * 1000,
        ),
      ),
      builder: (context, isOpen, open) => SoftActionTile(
        icon: Icons.battery_full,
        label: _capacityLabel(loc, separator),
        selected: isOpen,
        onPressed: _savingCapacity ? null : open,
      ),
    );
  }

  String _capacityLabel(AppLocalizations loc, String separator) {
    final kwh = (_packCapacityWh / 1000)
        .toStringAsFixed(2)
        .replaceAll('.', separator);
    return '$kwh ${loc.unitKwh}';
  }

  Future<void> _savePackCapacity(double? valueWh) async {
    final loc = AppLocalizations.of(context)!;
    clearStatus();
    setState(() => _savingCapacity = true);
    try {
      final settings = await _api.setPackCapacityWh(valueWh);
      if (!mounted) return;
      setState(() {
        _packCapacityWh = settings.packCapacityWh;
        _savingCapacity = false;
      });
      reportOk(
        loc.settingsPackCapacitySaved(
          _capacityLabel(loc, chargeDecimalSeparatorForLocale(loc.localeName)),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _savingCapacity = false);
      reportError('$error');
    }
  }

  Future<void> _applyDefaultChargeCost() {
    final loc = AppLocalizations.of(context)!;
    return runAction(
      setBusy: (busy) => _applyingChargeCost = busy,
      action: _api.applyDefaultChargeCostToUnpriced,
      describe: (result) {
        if (!result.ok) return loc.settingsChargeCostApplyNoRate;
        if (result.updatedRows == 0) return loc.settingsChargeCostApplyNone;
        return loc.settingsChargeCostApplied(result.updatedRows);
      },
      describeError: (error) => '$error',
    );
  }

  Widget _chargeCostTile(AppLocalizations loc) {
    final symbol = chargeCurrencySymbolForLocale(
      loc.localeName,
      fallbackCurrency: _chargeCostCurrency,
    );
    final separator = chargeDecimalSeparatorForLocale(loc.localeName);
    final saved = _defaultChargeCostPerKwh;
    return AnchoredTooltipTrigger(
      side: AnchoredTooltipSide.left,
      barrierLabel: loc.v2MoneyKeypadClose,
      tooltipBuilder: (context) => MoneyKeypadDialog<String>(
        fields: [
          MoneyKeypadField(
            value: 'rate',
            label: loc.v2ChargeCostFieldRate,
            amount: saved,
            unit: loc.v2ChargeCostUnitRate,
          ),
        ],
        currencySymbol: symbol,
        decimalSeparator: separator,
        title: loc.settingsChargeCostTitle,
        description: loc.settingsChargeCostDesc,
        saveLabel: loc.v2MoneyKeypadSave,
        clearLabel: loc.v2MoneyKeypadClear,
        deleteLabel: loc.v2MoneyKeypadDelete,
        onSubmitted: (result) => _saveDefaultChargeCost(result.amount),
      ),
      builder: (context, isOpen, open) => SoftActionTile(
        icon: Icons.payments,
        label: saved == null
            ? loc.settingsChargeCostNotSaved
            : chargeAmountLabel(
                saved,
                symbol: symbol,
                decimalSeparator: separator,
              ),
        selected: isOpen,
        onPressed: _savingChargeCost ? null : open,
      ),
    );
  }

  Future<void> _saveDefaultChargeCost(double? value) async {
    final loc = AppLocalizations.of(context)!;
    clearStatus();
    setState(() => _savingChargeCost = true);
    try {
      final settings = await _api.setDefaultChargeCostPerKwh(value);
      if (!mounted) return;
      setState(() {
        _defaultChargeCostPerKwh = settings.defaultChargeCostPerKwh;
        _chargeCostCurrency = settings.chargeCostCurrency;
        _savingChargeCost = false;
      });
      final rate = settings.defaultChargeCostPerKwh;
      reportOk(
        rate == null
            ? loc.settingsChargeCostNotSaved
            : loc.settingsChargeCostSaved(
                chargeAmountLabel(
                  rate,
                  symbol: chargeCurrencySymbolForLocale(
                    loc.localeName,
                    fallbackCurrency: settings.chargeCostCurrency,
                  ),
                  decimalSeparator: chargeDecimalSeparatorForLocale(
                    loc.localeName,
                  ),
                ),
              ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _savingChargeCost = false);
      reportError('$error');
    }
  }
}

class _ProposalButton extends StatelessWidget {
  const _ProposalButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.x3,
            vertical: AppSpacing.x2,
          ),
          child: Text(label, style: AppText.label),
        ),
      ),
    );
  }
}
