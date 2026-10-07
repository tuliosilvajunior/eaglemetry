import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/telemetry_api.dart';
import '../../core/telemetry_scope.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import 'settings_pane.dart';

/// System: the two things that get updated under the app, and what it says
/// about itself.
///
/// The app updater and the Roadcast daemon are one category because they are
/// one dependency chain — an app update installs a Roadcast update first — and
/// splitting them would hide that from whoever is trying to fix a version
/// mismatch.
class SystemPane extends StatefulWidget {
  const SystemPane({this.telemetryApi, this.packageInfo, super.key});

  /// Seam for tests. Production passes nothing and gets the real channel.
  final TelemetryApi? telemetryApi;

  /// Seam for tests: `PackageInfo.fromPlatform` needs a plugin.
  final PackageInfo? packageInfo;

  @override
  State<SystemPane> createState() => _SystemPaneState();
}

class _SystemPaneState extends State<SystemPane>
    with SettingsPaneState<SystemPane> {
  late final TelemetryApi _api =
      widget.telemetryApi ?? TelemetryScope.of(context);

  AppUpdateStatus? _appUpdate;
  RoadcastStatus? _roadcast;
  RoadcastUpdateStatus? _roadcastUpdate;
  PackageInfo? _packageInfo;

  bool _checkingApp = false;
  bool _installingApp = false;
  bool _restartingRoadcast = false;
  bool _checkingRoadcast = false;
  bool _updatingRoadcast = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Reads the three statuses the pane shows, each on its own, so one channel
  /// that is unavailable does not blank the other two.
  Future<void> _load() async {
    final packageInfo = widget.packageInfo;
    if (packageInfo != null) {
      _packageInfo = packageInfo;
    } else {
      try {
        final info = await PackageInfo.fromPlatform();
        if (mounted) setState(() => _packageInfo = info);
      } catch (_) {
        // Version stays `--`.
      }
    }
    await _read(_api.getAppUpdateStatus, (v) => _appUpdate = v);
    await _read(_api.getRoadcastStatus, (v) => _roadcast = v);
    await _read(_api.getRoadcastUpdateStatus, (v) => _roadcastUpdate = v);
  }

  Future<void> _read<R>(
    Future<R> Function() read,
    void Function(R) assign,
  ) async {
    try {
      final value = await read();
      if (mounted) setState(() => assign(value));
    } catch (_) {
      // A status the platform did not answer stays absent, and the pane says
      // "unavailable" rather than inventing one.
    }
  }

  Future<void> _checkAppUpdate() {
    final loc = AppLocalizations.of(context)!;
    return runAction(
      setBusy: (busy) => _checkingApp = busy,
      action: _api.checkAppUpdate,
      describe: (status) {
        setState(() => _appUpdate = status);
        return null;
      },
      describeError: (error) => loc.settingsAppUpdateCheckFailed('$error'),
    );
  }

  Future<void> _installAppUpdate() async {
    final loc = AppLocalizations.of(context)!;
    final update = _appUpdate;
    final confirmed = await showConfirmDialog(
      context: context,
      title: loc.settingsAppUpdateConfirmTitle(
        update?.availableVersionName ?? '--',
      ),
      message: loc.settingsAppUpdateConfirmDescription,
      confirmLabel: loc.settingsAppUpdateConfirmInstall,
      cancelLabel: loc.settingsAppUpdateConfirmCancel,
      barrierLabel: loc.settingsAppUpdateConfirmCancel,
    );
    if (confirmed != true || !mounted) return;
    await runAction(
      setBusy: (busy) => _installingApp = busy,
      action: _api.installAppUpdate,
      describe: (status) {
        setState(() => _appUpdate = status);
        return status.installScheduled ? loc.settingsAppUpdateScheduled : null;
      },
      describeError: (error) => loc.settingsAppUpdateInstallFailed('$error'),
    );
  }

  Future<void> _restartRoadcast() {
    final loc = AppLocalizations.of(context)!;
    return runAction(
      setBusy: (busy) => _restartingRoadcast = busy,
      action: _api.restartRoadcastDaemon,
      describe: (status) {
        setState(() => _roadcast = status);
        return loc.settingsRoadcastRestartSuccess;
      },
      describeError: (error) => loc.settingsRoadcastRestartFailed('$error'),
    );
  }

  Future<void> _checkRoadcastUpdate() {
    final loc = AppLocalizations.of(context)!;
    return runAction(
      setBusy: (busy) => _checkingRoadcast = busy,
      action: _api.checkRoadcastUpdate,
      describe: (status) {
        setState(() => _roadcastUpdate = status);
        return null;
      },
      describeError: (error) => loc.settingsRoadcastCheckFailed('$error'),
    );
  }

  Future<void> _updateRoadcast() {
    final loc = AppLocalizations.of(context)!;
    return runAction(
      setBusy: (busy) => _updatingRoadcast = busy,
      action: _api.updateRoadcastDaemon,
      describe: (status) {
        setState(() => _roadcastUpdate = status);
        return loc.settingsRoadcastUpdateSuccess(
          _shortIdentity(status.installedCommit ?? status.installedSha256),
        );
      },
      describeError: (error) => loc.settingsRoadcastUpdateFailed('$error'),
    );
  }

  static String _shortIdentity(String? value) {
    if (value == null || value.isEmpty) return '--';
    return value.length <= 12 ? value : value.substring(0, 12);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSections(
          children: [_appUpdateCard(loc), _roadcastCard(loc), _aboutCard(loc)],
        ),
        SettingsStatusLine(status: status),
      ],
    );
  }

  Widget _appUpdateCard(AppLocalizations loc) {
    final update = _appUpdate;
    final busy = _checkingApp || _installingApp;
    final canInstall =
        !busy &&
        update != null &&
        update.checked &&
        update.compatible &&
        update.updateAvailable;
    final detail = _checkingApp && update == null
        ? loc.settingsAppUpdateChecking
        : update == null || !update.checked
        ? loc.settingsAppUpdateNotChecked
        : update.installScheduled
        ? loc.settingsAppUpdateScheduled
        : !update.compatible
        ? loc.settingsAppUpdateIncompatible(
            update.error ?? loc.settingsAppUpdateUnavailable,
          )
        : update.updateAvailable
        ? loc.settingsAppUpdateAvailable(
            update.availableVersionName ?? '--',
            update.availableVersionCode ?? 0,
          )
        : loc.settingsAppUpdateUpToDate;

    return AppCard(
      title: loc.settingsAppUpdateTitle,
      subtitle: detail,
      child: SettingsRows(
        children: [
          SettingsEntry(
            title: loc.settingsAppUpdateDescription,
            description: '',
            child: Row(
              children: [
                Expanded(
                  child: SoftActionTile(
                    icon: Icons.refresh,
                    label: _checkingApp
                        ? loc.settingsAppUpdateChecking
                        : loc.settingsAppUpdateCheck,
                    centered: true,
                    onPressed: busy ? null : _checkAppUpdate,
                  ),
                ),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: SoftActionTile(
                    icon: Icons.system_update_alt,
                    label: _installingApp
                        ? loc.settingsAppUpdateInstalling
                        : loc.settingsAppUpdateInstall,
                    centered: true,
                    onPressed: canInstall ? _installAppUpdate : null,
                  ),
                ),
              ],
            ),
          ),
          if (update != null && update.changelog.isNotEmpty)
            _ReleaseNotes(entries: update.changelog),
        ],
      ),
    );
  }

  Widget _roadcastCard(AppLocalizations loc) {
    final daemon = _roadcast;
    final update = _roadcastUpdate;
    final busy = _restartingRoadcast || _checkingRoadcast || _updatingRoadcast;
    final canUpdate =
        !busy &&
        update != null &&
        update.checked &&
        update.compatible &&
        update.updateAvailable;
    final daemonDetail = daemon == null
        ? loc.settingsRoadcastUnavailable
        : daemon.running
        ? loc.settingsRoadcastRunning(
            daemon.frameCount,
            daemon.hz,
            daemon.signalCount,
          )
        : (daemon.error ?? loc.settingsRoadcastStopped);
    final updateDetail = update == null || !update.checked
        ? loc.settingsRoadcastNotChecked
        : !update.compatible
        ? loc.settingsRoadcastIncompatible(
            update.error ?? loc.settingsRoadcastStopped,
          )
        : update.updateAvailable
        ? loc.settingsRoadcastUpdateAvailable(
            _shortIdentity(update.availableCommit),
          )
        : loc.settingsRoadcastUpToDate;

    return AppCard(
      title: loc.settingsRoadcastTitle,
      subtitle: daemonDetail,
      child: SettingsRows(
        children: [
          SettingsEntry(
            title: loc.settingsRoadcastInstalled(
              _shortIdentity(
                update?.installedCommit ?? update?.installedSha256,
              ),
            ),
            description: updateDetail,
            child: Row(
              children: [
                Expanded(
                  child: SoftActionTile(
                    icon: Icons.restart_alt,
                    label: _restartingRoadcast
                        ? loc.settingsRoadcastRestarting
                        : loc.settingsRoadcastRestart,
                    centered: true,
                    onPressed: busy ? null : _restartRoadcast,
                  ),
                ),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: SoftActionTile(
                    icon: Icons.refresh,
                    label: _checkingRoadcast
                        ? loc.settingsRoadcastChecking
                        : loc.settingsRoadcastCheck,
                    centered: true,
                    onPressed: busy ? null : _checkRoadcastUpdate,
                  ),
                ),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: SoftActionTile(
                    icon: Icons.download,
                    label: _updatingRoadcast
                        ? loc.settingsRoadcastUpdating
                        : loc.settingsRoadcastUpdate,
                    centered: true,
                    onPressed: canUpdate ? _updateRoadcast : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _aboutCard(AppLocalizations loc) {
    final info = _packageInfo;
    final colors = AppThemeColors.of(context);
    return AppCard(
      title: loc.settingsSectionAbout,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loc.appTitle, style: AppText.body.copyWith(color: colors.ink)),
          const SizedBox(height: AppSpacing.x1),
          Text(
            info == null
                ? '--'
                // Generated placeholders are alphabetical, so `build` comes
                // first here even though it reads second.
                : loc.settingsAppVersion(info.buildNumber, info.version),
            style: AppText.body.copyWith(color: colors.ink),
          ),
          const SizedBox(height: AppSpacing.x1),
          Text(
            loc.settingsAboutDeveloper('@tuliosilvajunior'),
            style: AppText.label.copyWith(color: colors.inkMuted),
          ),
          Text(
            loc.settingsAboutTagline,
            style: AppText.label.copyWith(color: colors.inkMuted),
          ),
        ],
      ),
    );
  }
}

/// The notes of every release between the installed build and the available
/// one, newest first.
class _ReleaseNotes extends StatelessWidget {
  const _ReleaseNotes({required this.entries});

  final List<AppChangelogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    final languageCode = Localizations.localeOf(context).languageCode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          loc.settingsAppUpdateReleaseNotes,
          style: AppText.body.copyWith(color: colors.ink),
        ),
        for (final entry in entries) ...[
          const SizedBox(height: AppSpacing.x3),
          Text(
            entry.versionName,
            style: AppText.label.copyWith(color: colors.ink),
          ),
          for (final note in entry.notesForLanguage(languageCode))
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.x1),
              child: Text(
                '· $note',
                style: AppText.label.copyWith(color: colors.inkMuted),
              ),
            ),
        ],
      ],
    );
  }
}
