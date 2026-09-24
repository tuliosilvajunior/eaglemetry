import 'package:flutter/material.dart';

import '../../core/app_experience_controller.dart';
import '../../core/developer_tools_gate.dart';
import '../../core/signal_lab_controller.dart';
import '../../core/telemetry_api.dart';
import '../../core/telemetry_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../screens/roadcast_trace_screen.dart';
import '../../screens/sensor_lab_screen.dart';
import '../signal_lab_screen.dart';
import 'package:capy_ui/capy_ui.dart';
import 'settings_pane.dart';

/// Developer: the switch that reveals the engineering surfaces, those
/// surfaces, and the two experience switches.
///
/// The previous interface hid developer mode behind eight taps on the About
/// card. That is not carried over: here it is a plain switch, always visible,
/// and it can be turned back off — which tapping never could.
///
/// The engineering rows appear only while the switch is on. That is what makes
/// the switch mean something: with them always present it would be a label
/// with no effect.
class DeveloperPane extends StatefulWidget {
  const DeveloperPane({this.telemetryApi, super.key});

  /// Seam for tests. Production passes nothing and gets the real channel.
  final TelemetryApi? telemetryApi;

  @override
  State<DeveloperPane> createState() => _DeveloperPaneState();
}

class _DeveloperPaneState extends State<DeveloperPane>
    with SettingsPaneState<DeveloperPane> {
  late final TelemetryApi _api =
      widget.telemetryApi ?? TelemetryScope.of(context);

  /// Null until the first read lands — see the same rule in `DataPane`.
  bool? _debugEventFileEnabled;

  bool _markingHistory = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    DeveloperToolsGate.instance.addListener(_onGateChanged);
  }

  @override
  void dispose() {
    DeveloperToolsGate.instance.removeListener(_onGateChanged);
    super.dispose();
  }

  void _onGateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _api.getTelemetrySettings();
      if (!mounted) return;
      setState(() => _debugEventFileEnabled = settings.debugEventFileEnabled);
    } catch (_) {
      if (mounted) setState(() => _debugEventFileEnabled = null);
    }
  }

  Future<void> _setDebugEventFile(bool enabled) async {
    final loc = AppLocalizations.of(context)!;
    final previous = _debugEventFileEnabled;
    setState(() {
      _debugEventFileEnabled = enabled;
      clearStatus();
    });
    try {
      final settings = await _api.setDebugEventFileEnabled(enabled);
      if (!mounted) return;
      // The read-back, not the request.
      setState(() => _debugEventFileEnabled = settings.debugEventFileEnabled);
    } catch (error) {
      if (!mounted) return;
      setState(() => _debugEventFileEnabled = previous);
      reportError(loc.v2SettingsEventFileFailed('$error'));
    }
  }

  /// Marks the car's whole history for upload again, and states the count the
  /// car reported.
  Future<void> _markCloudHistoryDirty() {
    final loc = AppLocalizations.of(context)!;
    return runAction(
      setBusy: (busy) => _markingHistory = busy,
      action: _api.markCloudHistoryDirty,
      describe: loc.v2SettingsResendHistoryDone,
      describeError: (error) => loc.v2SettingsResendHistoryFailed('$error'),
    );
  }

  /// Closes the menu, then pushes the screen on the navigator that owned it.
  ///
  /// The order matters: the menu is a route, and pushing under it would leave
  /// the engineering screen behind a scrim the user cannot see past.
  void _open(WidgetBuilder builder, {VoidCallback? whenClosed}) {
    final navigator = Navigator.of(context);
    navigator.pop();
    final route = navigator.push(MaterialPageRoute<void>(builder: builder));
    if (whenClosed != null) route.whenComplete(whenClosed);
  }

  /// Opens the lab on its own route with its own controller.
  ///
  /// The controller is built here and disposed when the route closes, so the
  /// FFI bridge exists only while the screen is on screen. A lab that kept
  /// sampling behind the settings menu would cost 10 Hz of CPU for nothing.
  void _openSignalLab() {
    final controller = SignalLabController(source: RoadcastSignalSource());
    _open(
      (_) => SignalLabScreen(controller: controller),
      whenClosed: controller.dispose,
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final unlocked = DeveloperToolsGate.instance.unlocked;
    final eventFile = _debugEventFileEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSections(
          children: [
            SettingsRows(
              children: [
                SettingToggleRow(
                  label: loc.v2SettingsDeveloperMode,
                  description: loc.v2SettingsDeveloperModeDesc,
                  value: unlocked,
                  onChanged: DeveloperToolsGate.instance.setUnlocked,
                ),
                if (unlocked)
                  AppCard(
                    title: loc.v2SettingsEngineering,
                    child: SettingsRows(
                      children: [
                        SettingToggleRow(
                          label: loc.settingsEventFile,
                          description: loc.settingsEventFileDesc,
                          value: eventFile ?? false,
                          onChanged: eventFile == null
                              ? null
                              : _setDebugEventFile,
                        ),
                        SettingsEntry(
                          title: loc.v2SettingsResendHistory,
                          description: loc.v2SettingsResendHistoryDesc,
                          child: SoftActionTile(
                            key: const Key('settings-resend-history'),
                            icon: Icons.cloud_upload,
                            label: loc.v2SettingsResendHistoryAction,
                            onPressed: _markingHistory
                                ? null
                                : _markCloudHistoryDirty,
                          ),
                        ),
                        SettingsEntry(
                          title: loc.roadcastTraceTitle,
                          description: loc.v2SettingsTraceDesc,
                          child: SoftActionTile(
                            icon: Icons.timeline,
                            label: loc.settingsSensorLabOpen,
                            onPressed: () =>
                                _open((_) => const RoadcastTraceScreen()),
                          ),
                        ),
                        SettingsEntry(
                          title: loc.signalLabTitle,
                          description: loc.signalLabDescription,
                          child: SoftActionTile(
                            icon: Icons.biotech,
                            label: loc.signalLabOpen,
                            onPressed: _openSignalLab,
                          ),
                        ),
                        SettingsEntry(
                          title: loc.settingsSensorLab,
                          description: loc.settingsSensorLabDesc,
                          child: SoftActionTile(
                            icon: Icons.sensors,
                            label: loc.settingsSensorLabOpen,
                            onPressed: () =>
                                _open((_) => const SensorLabScreen()),
                          ),
                        ),
                      ],
                    ),
                  ),
                AppCard(
                  title: loc.v2SettingsExperience,
                  child: SettingsRows(
                    children: [
                      SettingToggleRow(
                        label: loc.v2ProjectionBetaTitle,
                        description: loc.v2ProjectionBetaDescription,
                        value:
                            AppExperienceController.instance.projectionEnabled,
                        onChanged: (enabled) async {
                          await AppExperienceController.instance
                              .setProjectionEnabled(enabled);
                          try {
                            await _api.setProjectionBetaEnabled(enabled);
                          } catch (_) {
                            // Nothing to report: the tab is what was asked for.
                          }
                          if (mounted) setState(() {});
                        },
                      ),
                      SettingsEntry(
                        title: loc.v2AppShellTitle,
                        description: loc.v2AppShellDescription,
                        child: SoftActionTile(
                          icon: Icons.arrow_back,
                          label: loc.v2AppShellAction,
                          onPressed: () {
                            // Close the menu first: the shell underneath is
                            // about to be replaced, and a route left open over
                            // it outlives the tree that pushed it.
                            Navigator.of(context).pop();
                            AppExperienceController.instance.setNewUiEnabled(
                              false,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        SettingsStatusLine(status: status),
      ],
    );
  }
}
