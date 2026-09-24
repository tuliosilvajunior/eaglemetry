import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bridge_call.dart';
import '../core/telemetry_api.dart';
import '../core/telemetry_scope.dart';
import '../design_system/design_system.dart';
import '../l10n/app_localizations.dart';

class HelpersScreen extends StatefulWidget {
  const HelpersScreen({super.key});

  @override
  State<HelpersScreen> createState() => _HelpersScreenState();
}

class _HelpersScreenState extends State<HelpersScreen> {
  late final TelemetryApi _api = TelemetryScope.of(context);
  bool _temperatureModeEnabled = false;
  bool _loadingSettings = true;
  bool _savingTemperatureMode = false;

  String? _loadError;
  String? _temperatureModeError;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final result = await callBridge(_api.getTelemetrySettings);
    if (!mounted) return;
    setState(() {
      _loadingSettings = false;
      switch (result) {
        case BridgeOk(:final value):
          _temperatureModeEnabled = value.temperatureModeHelperEnabled;
          _loadError = null;
        case BridgeFailure(:final message):
          _loadError = message;
      }
    });
  }

  Future<void> _reloadSettings() async {
    setState(() {
      _loadingSettings = true;
      _loadError = null;
    });
    await _loadSettings();
  }

  Future<void> _setTemperatureModeEnabled(bool enabled) async {
    HapticFeedback.selectionClick();
    setState(() {
      _temperatureModeEnabled = enabled;
      _savingTemperatureMode = true;
      _temperatureModeError = null;
    });
    final result = await callBridge(
      () => _api.setTemperatureModeHelperEnabled(enabled),
    );
    if (!mounted) return;
    setState(() {
      _savingTemperatureMode = false;
      switch (result) {
        case BridgeOk(:final value):
          _temperatureModeEnabled = value.temperatureModeHelperEnabled;
        case BridgeFailure(:final message):
          _temperatureModeEnabled = !enabled;
          _temperatureModeError = message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final loadError = _loadError;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          ScreenHeaderBar(
            title: loc.helpersTitle,
            subtitle: loc.helpersSubtitle,
          ),
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: AutomotiveSpacing.screenPadding,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (loadError != null) ...[
                          ErrorPanel(
                            message: loadError,
                            icon: Icons.error_outline,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x1),
                          TechnicalButton(
                            icon: Icons.refresh,
                            label: loc.helpersRetry,
                            onPressed: _loadingSettings
                                ? null
                                : _reloadSettings,
                          ),
                          const SizedBox(height: AutomotiveSpacing.x3),
                        ],
                        SectionHeader(
                          icon: Icons.device_hub,
                          label: loc.helpersTemperatureSection,
                        ),
                        const SizedBox(height: AutomotiveSpacing.x1),
                        _TemperatureModePanel(
                          enabled: _temperatureModeEnabled,
                          busy: _loadingSettings || _savingTemperatureMode,
                          error: _temperatureModeError,
                          onChanged: _loadingSettings || _savingTemperatureMode
                              ? null
                              : _setTemperatureModeEnabled,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TemperatureModePanel extends StatelessWidget {
  const _TemperatureModePanel({
    required this.enabled,
    required this.busy,
    required this.error,
    required this.onChanged,
  });

  final bool enabled;
  final bool busy;
  final String? error;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return TechnicalPanel(
      borderRadius: AutomotiveRadii.baseRadius,
      child: Row(
        children: [
          Icon(
            Icons.thermostat,
            color: enabled ? colors.secondary : colors.onSurfaceVariant,
          ),
          const SizedBox(width: AutomotiveSpacing.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loc.helpersTemperatureModeTitle,
                  style: AutomotiveTextStyles.bodyMd.copyWith(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AutomotiveSpacing.x0_5),
                Text(
                  loc.helpersTemperatureModeDesc,
                  style: AutomotiveTextStyles.bodyMd.copyWith(
                    color: colors.onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AutomotiveSpacing.x2),
          if (busy)
            const SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Switch(value: enabled, onChanged: onChanged),
          if (error != null) ...[
            const SizedBox(width: AutomotiveSpacing.x2),
            Flexible(
              child: Text(
                error!,
                overflow: TextOverflow.ellipsis,
                style: AutomotiveTextStyles.unitLabel.copyWith(
                  color: colors.error,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
