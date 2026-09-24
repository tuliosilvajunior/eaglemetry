import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_confetti/flutter_confetti.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/app_experience_controller.dart';
import '../core/developer_tools_gate.dart';
import '../core/telemetry_api.dart';
import '../core/telemetry_scope.dart';
import '../core/theme_controller.dart';
import '../design_system/design_system.dart';
import '../widgets/charge_cost_cryptex.dart';
import 'sensor_lab_screen.dart';
import 'package:capy_energy/l10n/app_localizations.dart';

part 'settings/about_panels.dart';
part 'settings/appearance_panels.dart';
part 'settings/maintenance_panels.dart';
part 'settings/roadcast_panel.dart';
part 'settings/telemetry_preferences_panels.dart';

ColorScheme _colors(BuildContext context) => Theme.of(context).colorScheme;

String _shortRoadcastIdentity(String? value) {
  if (value == null || value.isEmpty) return '--';
  return value.length <= 12 ? value : value.substring(0, 12);
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TelemetryApi _telemetryApi = TelemetryScope.of(context);

  bool _clearing = false;
  bool _runningRetention = false;
  bool _restartingRoadcast = false;
  bool _checkingRoadcastUpdate = false;
  bool _updatingRoadcast = false;
  bool _checkingAppUpdate = true;
  bool _installingAppUpdate = false;
  AppUpdateStatus? _appUpdateStatus;
  String? _updateAlertMessage;
  RoadcastStatus? _roadcastStatus;
  RoadcastUpdateStatus? _roadcastUpdateStatus;
  bool _loadingSettings = true;
  bool _autoStartOnBoot = true;
  bool _gpsEnabled = false;
  bool _debugEventFileEnabled = false;
  bool _replaceOemChargingEnabled = false;
  double? _defaultChargeCostPerKwh;
  double? _draftChargeCostPerKwh;
  String _chargeCostCurrency = 'BRL';
  String? _status;
  bool _statusIsError = false;
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    _loadTelemetrySettings();
    _loadPackageInfo();
    _checkAppUpdate();
    _loadRoadcastStatus();
    _loadRoadcastUpdateStatus();
  }

  Future<void> _loadPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _packageInfo = info);
  }

  Future<void> _checkAppUpdate() async {
    if (!_checkingAppUpdate) {
      setState(() {
        _checkingAppUpdate = true;
        _updateAlertMessage = null;
      });
    }
    try {
      final status = await _telemetryApi.checkAppUpdate();
      if (!mounted) return;
      setState(() {
        _appUpdateStatus = status;
        _checkingAppUpdate = false;
        _updateAlertMessage = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checkingAppUpdate = false;
        _raiseUpdateAlert(
          AppLocalizations.of(
            context,
          )!.settingsAppUpdateCheckFailed(_formatUpdateError(error)),
        );
      });
    }
  }

  Future<void> _installAppUpdate() async {
    final loc = AppLocalizations.of(context)!;
    setState(() {
      _installingAppUpdate = true;
      _status = null;
      _statusIsError = false;
      _updateAlertMessage = null;
    });
    try {
      final status = await _telemetryApi.installAppUpdate();
      if (!mounted) return;
      setState(() {
        _appUpdateStatus = status;
        _installingAppUpdate = false;
        _status = loc.settingsAppUpdateScheduled;
        _updateAlertMessage = null;
      });
      HapticFeedback.mediumImpact();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _installingAppUpdate = false;
        _raiseUpdateAlert(
          loc.settingsAppUpdateInstallFailed(_formatUpdateError(error)),
        );
      });
      HapticFeedback.heavyImpact();
    }
  }

  Future<void> _confirmAppUpdate() async {
    final update = _appUpdateStatus;
    if (update == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _AppUpdateConfirmationDialog(status: update),
    );
    if (confirmed == true && mounted) await _installAppUpdate();
  }

  void _raiseUpdateAlert(String message) {
    _updateAlertMessage = message;
    _status = null;
    _statusIsError = false;
  }

  void _dismissUpdateAlert() {
    setState(() => _updateAlertMessage = null);
  }

  String _formatUpdateError(Object error) {
    if (error is PlatformException) {
      return error.message ?? error.code;
    }
    return error.toString();
  }

  Future<void> _loadTelemetrySettings() async {
    try {
      final settings = await _telemetryApi.getTelemetrySettings();
      if (!mounted) return;
      setState(() {
        _autoStartOnBoot = settings.autoStartOnBoot;
        _gpsEnabled = settings.gpsEnabled;
        _debugEventFileEnabled = settings.debugEventFileEnabled;
        _replaceOemChargingEnabled = settings.replaceOemChargingEnabled;
        _defaultChargeCostPerKwh = settings.defaultChargeCostPerKwh;
        _draftChargeCostPerKwh = settings.defaultChargeCostPerKwh ?? 0.0;
        _chargeCostCurrency = settings.chargeCostCurrency;
        _loadingSettings = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingSettings = false;
        _status = 'SETTINGS LOAD FAILED: $error';
        _statusIsError = true;
      });
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _setAutoStartOnBoot(bool enabled) async {
    setState(() {
      _autoStartOnBoot = enabled;
      _status = null;
      _statusIsError = false;
    });
    try {
      final settings = await _telemetryApi.setAutoStartOnBoot(enabled);
      if (!mounted) return;
      setState(() {
        _autoStartOnBoot = settings.autoStartOnBoot;
        _status =
            'AUTO-START ON BOOT ${settings.autoStartOnBoot ? 'ENABLED' : 'DISABLED'}';
      });
      HapticFeedback.selectionClick();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _autoStartOnBoot = !enabled;
        _status = 'AUTO-START UPDATE FAILED: $error';
        _statusIsError = true;
      });
      HapticFeedback.heavyImpact();
    }
  }

  Future<void> _setGpsEnabled(bool enabled) async {
    setState(() {
      _gpsEnabled = enabled;
      _status = null;
      _statusIsError = false;
    });
    try {
      final settings = await _telemetryApi.setGpsEnabled(enabled);
      if (!mounted) return;
      setState(() {
        _gpsEnabled = settings.gpsEnabled;
        _status =
            'GPS COLLECTION ${settings.gpsEnabled ? 'ENABLED' : 'DISABLED'}';
      });
      HapticFeedback.selectionClick();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _gpsEnabled = !enabled;
        _status = 'GPS UPDATE FAILED: $error';
        _statusIsError = true;
      });
      HapticFeedback.heavyImpact();
    }
  }

  Future<void> _setReplaceOemChargingEnabled(bool enabled) async {
    setState(() {
      _replaceOemChargingEnabled = enabled;
      _status = null;
      _statusIsError = false;
    });
    try {
      final settings = await _telemetryApi.setReplaceOemChargingEnabled(
        enabled,
      );
      if (!mounted) return;
      setState(() {
        _replaceOemChargingEnabled = settings.replaceOemChargingEnabled;
        _status =
            'REPLACE OEM CHARGING ${settings.replaceOemChargingEnabled ? 'ENABLED' : 'DISABLED'}';
      });
      HapticFeedback.selectionClick();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _replaceOemChargingEnabled = !enabled;
        _status = 'REPLACE OEM CHARGING UPDATE FAILED: $error';
        _statusIsError = true;
      });
      HapticFeedback.heavyImpact();
    }
  }

  Future<void> _setDebugEventFileEnabled(bool enabled) async {
    setState(() {
      _debugEventFileEnabled = enabled;
      _status = null;
      _statusIsError = false;
    });
    try {
      final settings = await _telemetryApi.setDebugEventFileEnabled(enabled);
      if (!mounted) return;
      setState(() {
        _debugEventFileEnabled = settings.debugEventFileEnabled;
        _status =
            'DEBUG EVENT FILE ${settings.debugEventFileEnabled ? 'ENABLED' : 'DISABLED'}';
      });
      HapticFeedback.selectionClick();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _debugEventFileEnabled = !enabled;
        _status = 'DEBUG EVENT FILE UPDATE FAILED: $error';
        _statusIsError = true;
      });
      HapticFeedback.heavyImpact();
    }
  }

  void _setDraftChargeCost(double value) {
    final next = value.clamp(0.0, 99.99).toDouble();
    setState(() {
      _draftChargeCostPerKwh = double.parse(next.toStringAsFixed(2));
      _status = null;
      _statusIsError = false;
    });
  }

  Future<void> _saveDefaultChargeCost({bool clear = false}) async {
    final value = clear ? null : (_draftChargeCostPerKwh ?? 0.0);
    setState(() {
      _status = null;
      _statusIsError = false;
    });
    try {
      final settings = await _telemetryApi.setDefaultChargeCostPerKwh(value);
      if (!mounted) return;
      setState(() {
        _defaultChargeCostPerKwh = settings.defaultChargeCostPerKwh;
        _draftChargeCostPerKwh = settings.defaultChargeCostPerKwh ?? 0.0;
        _chargeCostCurrency = settings.chargeCostCurrency;
        _status = settings.defaultChargeCostPerKwh == null
            ? 'PRECO PADRAO DE CARGA REMOVIDO'
            : 'PRECO PADRAO DE CARGA SALVO';
      });
      HapticFeedback.selectionClick();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = 'FALHA SALVAR PRECO DE CARGA: $error';
        _statusIsError = true;
      });
      HapticFeedback.heavyImpact();
    }
  }

  Future<void> _confirmClearDatabase() async {
    HapticFeedback.selectionClick();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => const _ClearDatabaseDialog(),
    );
    if (confirmed != true) return;
    await _clearDatabase();
  }

  Future<void> _clearDatabase() async {
    setState(() {
      _clearing = true;
      _status = null;
      _statusIsError = false;
    });

    try {
      final result = await _telemetryApi.clearTelemetryDatabase();
      if (!mounted) return;
      setState(() {
        _status =
            'DATABASE CLEARED: ${result.totalRowsDeleted} ROWS '
            '(${result.chargeSessionsDeleted} CHARGE, '
            '${result.tripSessionsDeleted} TRIP, '
            '${result.telemetryFramesDeleted} FRAME, '
            '${result.sessionAggregatesDeleted} AGGREGATE, '
            '${result.telemetryEventsDeleted} EVENT)';
      });
      HapticFeedback.mediumImpact();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = 'DATABASE CLEAR FAILED: $error';
        _statusIsError = true;
      });
      HapticFeedback.heavyImpact();
    } finally {
      if (mounted) {
        setState(() => _clearing = false);
      }
    }
  }

  Future<void> _loadRoadcastStatus() async {
    try {
      final status = await _telemetryApi.getRoadcastStatus();
      if (!mounted) return;
      setState(() => _roadcastStatus = status);
    } catch (_) {
      // Estado do daemon é informativo: falhar em lê-lo não deve quebrar a tela
      // inteira de configurações.
      if (!mounted) return;
      setState(() => _roadcastStatus = null);
    }
  }

  Future<void> _loadRoadcastUpdateStatus() async {
    try {
      final status = await _telemetryApi.getRoadcastUpdateStatus();
      if (!mounted) return;
      setState(() => _roadcastUpdateStatus = status);
    } catch (_) {
      if (!mounted) return;
      setState(() => _roadcastUpdateStatus = null);
    }
  }

  Future<void> _checkRoadcastUpdate() async {
    final loc = AppLocalizations.of(context)!;
    setState(() {
      _checkingRoadcastUpdate = true;
      _status = null;
      _statusIsError = false;
      _updateAlertMessage = null;
    });
    try {
      final status = await _telemetryApi.checkRoadcastUpdate();
      if (!mounted) return;
      setState(() {
        _roadcastUpdateStatus = status;
        _updateAlertMessage = null;
        _statusIsError = !status.compatible;
        _status = status.compatible
            ? null
            : loc.settingsRoadcastIncompatible(
                status.error ?? loc.settingsRoadcastStopped,
              );
      });
      HapticFeedback.selectionClick();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _raiseUpdateAlert(
          loc.settingsRoadcastCheckFailed(_formatUpdateError(error)),
        );
      });
      HapticFeedback.heavyImpact();
    } finally {
      if (mounted) {
        setState(() => _checkingRoadcastUpdate = false);
      }
    }
  }

  Future<void> _updateRoadcast() async {
    final loc = AppLocalizations.of(context)!;
    setState(() {
      _updatingRoadcast = true;
      _status = null;
      _statusIsError = false;
      _updateAlertMessage = null;
    });
    try {
      final update = await _telemetryApi.updateRoadcastDaemon();
      final daemon = await _telemetryApi.getRoadcastStatus();
      if (!mounted) return;
      setState(() {
        _roadcastUpdateStatus = update;
        _roadcastStatus = daemon;
        _status = loc.settingsRoadcastUpdateSuccess(
          _shortRoadcastIdentity(update.installedCommit),
        );
        _updateAlertMessage = null;
      });
      HapticFeedback.mediumImpact();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _raiseUpdateAlert(
          loc.settingsRoadcastUpdateFailed(_formatUpdateError(error)),
        );
      });
      HapticFeedback.heavyImpact();
    } finally {
      if (mounted) {
        setState(() => _updatingRoadcast = false);
      }
    }
  }

  Future<void> _restartRoadcast() async {
    final loc = AppLocalizations.of(context)!;
    setState(() {
      _restartingRoadcast = true;
      _status = null;
      _statusIsError = false;
    });

    try {
      final status = await _telemetryApi.restartRoadcastDaemon();
      if (!mounted) return;
      setState(() {
        _roadcastStatus = status;
        _statusIsError = !status.running;
        _status = status.running
            ? loc.settingsRoadcastRestartSuccess
            : loc.settingsRoadcastRestartFailed(
                status.error ?? loc.settingsRoadcastStopped,
              );
      });
      if (status.running) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.heavyImpact();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = loc.settingsRoadcastRestartFailed(error.toString());
        _statusIsError = true;
      });
      HapticFeedback.heavyImpact();
    } finally {
      if (mounted) {
        setState(() => _restartingRoadcast = false);
      }
    }
  }

  Future<void> _runRetention() async {
    setState(() {
      _runningRetention = true;
      _status = null;
      _statusIsError = false;
    });

    try {
      final result = await _telemetryApi.runTelemetryRetention();
      if (!mounted) return;
      setState(() {
        _status =
            'RETENTION COMPLETE: ${result.aggregatesUpserted} AGGREGATES, '
            '${result.telemetryFramesDeleted} FRAMES DELETED, '
            '${result.telemetryEventsDeleted} EVENTS DELETED '
            '(RAW RETENTION ${result.retentionDays} DAYS)';
      });
      HapticFeedback.mediumImpact();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = 'RETENTION FAILED: $error';
        _statusIsError = true;
      });
      HapticFeedback.heavyImpact();
    } finally {
      if (mounted) {
        setState(() => _runningRetention = false);
      }
    }
  }

  Widget _buildUpdateAlert(AppLocalizations loc) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      reverseDuration: const Duration(milliseconds: 180),
      transitionBuilder: (child, animation) {
        final slide =
            Tween<Offset>(
              begin: const Offset(0, -0.18),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              ),
            );
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: _updateAlertMessage == null
          ? const SizedBox.shrink()
          : TopAlertBanner(
              key: ValueKey(_updateAlertMessage),
              title: loc.settingsUpdateAlertTitle,
              message: _updateAlertMessage!,
              dismissLabel: loc.settingsUpdateAlertDismiss,
              onDismiss: _dismissUpdateAlert,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final loc = AppLocalizations.of(context)!;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: AutomotiveSpacing.screenPadding,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 920),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            loc.settingsSectionSystem,
                            style: AutomotiveTextStyles.labelCaps.copyWith(
                              color: colorScheme.secondary,
                            ),
                          ),
                          const SizedBox(height: AutomotiveSpacing.x1),
                          Text(
                            loc.settingsTitle,
                            style: AutomotiveTextStyles.headlineLg.copyWith(
                              color: colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: AutomotiveSpacing.x1),
                          Text(
                            loc.settingsDescription,
                            style: AutomotiveTextStyles.bodyMd.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: AutomotiveSpacing.x6),
                          SectionHeader(
                            icon: Icons.settings_suggest,
                            label: loc.settingsSectionGeneral,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x1),
                          const _ThemePanel(),
                          const SizedBox(height: AutomotiveSpacing.x2),
                          _AutoStartPanel(
                            loading: _loadingSettings,
                            enabled: _autoStartOnBoot,
                            onChanged: _setAutoStartOnBoot,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x2),
                          _GpsPanel(
                            loading: _loadingSettings,
                            enabled: _gpsEnabled,
                            onChanged: _setGpsEnabled,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x2),
                          _ReplaceOemChargingPanel(
                            loading: _loadingSettings,
                            enabled: _replaceOemChargingEnabled,
                            onChanged: _setReplaceOemChargingEnabled,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x4),
                          SectionHeader(
                            icon: Icons.storage,
                            label: loc.settingsSectionData,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x1),
                          _RetentionPanel(
                            running: _runningRetention,
                            onRun: _runRetention,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x2),
                          _EventFilePanel(
                            loading: _loadingSettings,
                            enabled: _debugEventFileEnabled,
                            onChanged: _setDebugEventFileEnabled,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x2),
                          _ChargeCostSettingsPanel(
                            loading: _loadingSettings,
                            currency: _chargeCostCurrency,
                            currentValue: _defaultChargeCostPerKwh,
                            draftValue: _draftChargeCostPerKwh ?? 0.0,
                            onChanged: _setDraftChargeCost,
                            onClear: () => _saveDefaultChargeCost(clear: true),
                            onSave: () => _saveDefaultChargeCost(),
                          ),
                          const SizedBox(height: AutomotiveSpacing.x2),
                          _RoadcastPanel(
                            restarting: _restartingRoadcast,
                            checking: _checkingRoadcastUpdate,
                            updating: _updatingRoadcast,
                            status: _roadcastStatus,
                            updateStatus: _roadcastUpdateStatus,
                            onRestart: _restartRoadcast,
                            onCheck: _checkRoadcastUpdate,
                            onUpdate: _updateRoadcast,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x2),
                          const _SensorLabPanel(),
                          const SizedBox(height: AutomotiveSpacing.x2),
                          _DangerPanel(
                            clearing: _clearing,
                            status: _status,
                            statusIsError: _statusIsError,
                            onClear: _confirmClearDatabase,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x4),
                          SectionHeader(
                            icon: Icons.info_outline,
                            label: loc.settingsSectionAbout,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x1),
                          _AppUpdatePanel(
                            checking: _checkingAppUpdate,
                            installing: _installingAppUpdate,
                            status: _appUpdateStatus,
                            onCheck: _checkAppUpdate,
                            onInstall: _confirmAppUpdate,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x2),
                          const _AboutPanel(),
                          const Padding(
                            padding: EdgeInsets.only(top: AutomotiveSpacing.x2),
                            child: _AppShellPanel(),
                          ),
                          if (_packageInfo != null) ...[
                            const SizedBox(height: AutomotiveSpacing.x4),
                            Center(
                              child: Text(
                                loc.settingsAppVersion(
                                  _packageInfo!.version,
                                  _packageInfo!.buildNumber,
                                ),
                                style: AutomotiveTextStyles.labelCaps.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Positioned(
              top: AutomotiveSpacing.x2,
              left: AutomotiveSpacing.x3,
              right: AutomotiveSpacing.x3,
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: _buildUpdateAlert(loc),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
