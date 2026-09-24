import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/telemetry_api.dart';
import '../../core/telemetry_scope.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import 'settings_pane.dart';

/// Data: what the collector records, how long it is kept, and how it leaves
/// or re-enters the app.
///
/// Three sections, in the order a user meets them: what is collected, what
/// happens to it over time, and the one action that destroys it.
class DataPane extends StatefulWidget {
  const DataPane({this.telemetryApi, super.key});

  /// Seam for tests. Production passes nothing and gets the real channel.
  final TelemetryApi? telemetryApi;

  @override
  State<DataPane> createState() => _DataPaneState();
}

class _DataPaneState extends State<DataPane> with SettingsPaneState<DataPane> {
  late final TelemetryApi _api =
      widget.telemetryApi ?? TelemetryScope.of(context);

  /// Null until the first read lands. A tri-state rather than a bool, because
  /// a switch defaulted to `false` before the collector has answered is a
  /// claim about the setting that nothing measured.
  bool? _gpsEnabled;
  bool? _keepBluetoothOn;
  bool? _autoStartOnBoot;
  bool? _continuousModeEnabled;

  bool _runningRetention = false;
  bool _clearing = false;

  /// How much disk the app's stored history occupies. Measured without
  /// scanning any row: the native side answers with file length / page metadata.
  StorageUsage? _storageUsage;
  bool _loadingStorage = true;
  String? _storageError;
  StreamSubscription<SessionChange>? _storageSub;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadStorage();
    // The number updates when history is added or the archive is wiped,
    // via the same stream lists use to avoid polling.
    _storageSub = _api.sessionChanges().listen((_) => _loadStorage());
  }

  @override
  void dispose() {
    _storageSub?.cancel();
    super.dispose();
  }

  Future<void> _loadStorage() async {
    try {
      final usage = await _api.getStorageUsage();
      if (!mounted) return;
      setState(() {
        _storageUsage = usage;
        _loadingStorage = false;
        _storageError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingStorage = false;
        _storageError = '$error';
      });
    }
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _api.getTelemetrySettings();
      if (!mounted) return;
      setState(() {
        _gpsEnabled = settings.gpsEnabled;
        _keepBluetoothOn = settings.keepBluetoothOn;
        _autoStartOnBoot = settings.autoStartOnBoot;
        _continuousModeEnabled = settings.continuousModeEnabled;
      });
    } catch (_) {
      // The switches stay inoperable rather than showing a guessed state.
      if (mounted) {
        setState(() {
          _gpsEnabled = null;
          _keepBluetoothOn = null;
          _autoStartOnBoot = null;
          _continuousModeEnabled = null;
        });
      }
    }
  }

  /// Applies a switch and keeps the **read-back**, not the request, so a write
  /// the collector rejected stays visible instead of being echoed.
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

  static bool _readGps(TelemetrySettingsResult settings) => settings.gpsEnabled;
  static bool _readKeepBluetoothOn(TelemetrySettingsResult settings) =>
      settings.keepBluetoothOn;
  static bool _readAutoStart(TelemetrySettingsResult settings) =>
      settings.autoStartOnBoot;
  static bool _readContinuousMode(TelemetrySettingsResult settings) =>
      settings.continuousModeEnabled;

  Future<void> _runRetention() {
    final loc = AppLocalizations.of(context)!;
    return runAction(
      setBusy: (busy) => _runningRetention = busy,
      action: _api.runTelemetryRetention,
      describe: (result) => loc.v2SettingsRetentionDone(
        result.telemetryFramesDeleted,
        result.retentionDays,
      ),
      describeError: (error) => loc.settingsRetentionFailed('$error'),
    ).whenComplete(_loadStorage);
  }

  Future<void> _clearDatabase() async {
    final loc = AppLocalizations.of(context)!;
    final confirmed = await showConfirmDialog(
      context: context,
      title: loc.settingsWipeDialogTitle,
      message: loc.settingsWipeDialogContent,
      confirmLabel: loc.settingsWipeAll,
      cancelLabel: loc.settingsCancel,
      barrierLabel: loc.settingsCancel,
      destructive: true,
    );
    if (confirmed != true || !mounted) return;
    await runAction(
      setBusy: (busy) => _clearing = busy,
      action: _api.clearTelemetryDatabase,
      describe: (result) => loc.v2SettingsWipeDone(
        result.tripSessionsDeleted,
        result.chargeSessionsDeleted,
        result.telemetryFramesDeleted,
      ),
      describeError: (error) => loc.v2SettingsWipeFailed('$error'),
    );
    await _loadStorage();
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSections(
          children: [
            _operationCard(loc),
            _storageCard(loc),
            _retentionCard(loc),
            _dangerCard(loc),
          ],
        ),
        SettingsStatusLine(status: status),
      ],
    );
  }

  Widget _operationCard(AppLocalizations loc) {
    final gpsEnabled = _gpsEnabled;
    final keepBluetoothOn = _keepBluetoothOn;
    final autoStart = _autoStartOnBoot;
    final continuousMode = _continuousModeEnabled;
    return AppCard(
      title: loc.v2SettingsOperation,
      child: SettingsRows(
        children: [
          SettingToggleRow(
            label: loc.settingsAutoStart,
            description: loc.settingsAutoStartDesc,
            value: autoStart ?? false,
            onChanged: autoStart == null
                ? null
                : (enabled) => _applySwitch(
                    requested: enabled,
                    previous: autoStart,
                    write: _api.setAutoStartOnBoot,
                    read: _readAutoStart,
                    assign: (value) => _autoStartOnBoot = value,
                    describeError: (error) =>
                        loc.v2SettingsAutoStartFailed('$error'),
                  ),
          ),
          SettingToggleRow(
            label: loc.settingsGps,
            description: loc.settingsGpsDesc,
            value: gpsEnabled ?? false,
            onChanged: gpsEnabled == null
                ? null
                : (enabled) => _applySwitch(
                    requested: enabled,
                    previous: gpsEnabled,
                    write: _api.setGpsEnabled,
                    read: _readGps,
                    assign: (value) => _gpsEnabled = value,
                    describeError: (error) => loc.settingsGpsError('$error'),
                  ),
          ),
          SettingToggleRow(
            label: loc.settingsKeepBluetoothOnTitle,
            description: loc.settingsKeepBluetoothOnDesc,
            value: keepBluetoothOn ?? false,
            onChanged: keepBluetoothOn == null
                ? null
                : (enabled) => _applySwitch(
                    requested: enabled,
                    previous: keepBluetoothOn,
                    write: _api.setKeepBluetoothOnEnabled,
                    read: _readKeepBluetoothOn,
                    assign: (value) => _keepBluetoothOn = value,
                    describeError: (error) =>
                        loc.settingsKeepBluetoothOnFailed('$error'),
                  ),
          ),
          SettingToggleRow(
            label: loc.settingsContinuousMode,
            description: loc.settingsContinuousModeDesc,
            value: continuousMode ?? false,
            onChanged: continuousMode == null
                ? null
                : (enabled) => _applySwitch(
                    requested: enabled,
                    previous: continuousMode,
                    write: _api.setContinuousModeEnabled,
                    read: _readContinuousMode,
                    assign: (value) => _continuousModeEnabled = value,
                    describeError: (error) =>
                        loc.settingsContinuousModeFailed('$error'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _storageCard(AppLocalizations loc) {
    final usage = _storageUsage;
    final error = _storageError;
    final String label;
    if (_loadingStorage) {
      label = loc.v2SettingsStorageLoading;
    } else if (error != null) {
      label = loc.v2SettingsStorageFailed(error);
    } else if (usage == null) {
      label = loc.v2SettingsStorageLoading;
    } else {
      label = loc.v2SettingsStorageValue(
        formatStorageBytes(usage.bytes, locale: loc.localeName),
      );
    }
    return AppCard(
      title: loc.v2SettingsStorage,
      child: SettingsRows(
        children: [
          SettingsEntry(
            title: loc.v2SettingsStorageTitle,
            description: loc.v2SettingsStorageDesc,
            child: SoftActionTile(
              key: const Key('settings-storage-tile'),
              icon: Icons.storage,
              label: label,
              onPressed: _loadingStorage ? null : _loadStorage,
            ),
          ),
        ],
      ),
    );
  }

  Widget _retentionCard(AppLocalizations loc) {
    return AppCard(
      title: loc.v2SettingsRetention,
      child: SettingsRows(
        children: [
          SettingsEntry(
            title: loc.settingsRetention,
            description: loc.settingsRetentionDesc,
            child: SoftActionTile(
              icon: Icons.cleaning_services,
              label: _runningRetention
                  ? loc.settingsRetentionRunning
                  : loc.settingsRetentionRun,
              onPressed: _runningRetention ? null : _runRetention,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dangerCard(AppLocalizations loc) {
    return AppCard(
      title: loc.v2SettingsDanger,
      child: SettingsEntry(
        title: loc.settingsWipe,
        description: loc.settingsWipeDesc,
        child: SoftActionTile(
          icon: Icons.delete_forever,
          iconColor: AppThemeColors.of(context).energy.critical,
          label: _clearing ? loc.settingsWiping : loc.settingsWipeHistory,
          onPressed: _clearing ? null : _clearDatabase,
        ),
      ),
    );
  }
}
