import 'package:flutter/material.dart';

import '../../core/app_experience_controller.dart';
import '../../core/car_settings_source.dart';
import '../../core/efficiency_unit.dart';
import '../../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';

/// Displays: everything about how the app looks on the head unit.
class DisplaysPane extends StatefulWidget {
  const DisplaysPane({super.key});

  @override
  State<DisplaysPane> createState() => _DisplaysPaneState();
}

class _DisplaysPaneState extends State<DisplaysPane> {
  late final CarSettingsSource _source = CarSettingsSource();
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
    final loc = AppLocalizations.of(context)!;
    return SettingsSections(
      children: [
        AppCard(
          title: loc.v2SettingsAppearance,
          child: SettingsRows(
            children: [
              // Shared body: theme + toggles slices persisted via adapters.
              AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => SettingsBody(
                  themeId: _controller.themeId,
                  onThemeChanged: _controller.setThemeId,
                  reduceMotion: _controller.reduceMotion,
                  onReduceMotionChanged: _controller.setReduceMotion,
                  capabilities: SurfaceCapabilities.of(context),
                ),
              ),
              SettingsEntry(
                title: loc.settingsEfficiencyUnit,
                description: loc.settingsEfficiencyUnitDesc,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ListenableBuilder(
                    listenable: EfficiencyUnitController.instance,
                    builder: (context, _) =>
                        TrackSegmentedControl<EfficiencyUnit>(
                          items: [
                            for (final unit in EfficiencyUnit.values)
                              TabItem(
                                value: unit,
                                label: efficiencyUnitSuffix(unit, loc),
                              ),
                          ],
                          selected: EfficiencyUnitController.instance.unit,
                          onSelected: (unit) =>
                              EfficiencyUnitController.instance.setUnit(unit),
                        ),
                  ),
                ),
              ),
              SettingToggleRow(
                label: loc.v2SettingsImmersive,
                description: loc.v2SettingsImmersiveDesc,
                value: AppExperienceController.instance.immersiveEnabled,
                onChanged: (enabled) async {
                  await AppExperienceController.instance.setImmersiveEnabled(
                    enabled,
                  );
                  if (mounted) setState(() {});
                },
              ),
              SettingToggleRow(
                label: loc.v2SettingsClimateBar,
                description: loc.v2SettingsClimateBarDesc,
                value: AppExperienceController.instance.climateBarEnabled,
                onChanged: (enabled) async {
                  await AppExperienceController.instance.setClimateBarEnabled(
                    enabled,
                  );
                  if (mounted) setState(() {});
                },
              ),
              // Only in the windowed mode. Immersive hides both bars already,
              // so the row would be a control with nothing to do.
              if (!AppExperienceController.instance.immersiveEnabled)
                SettingToggleRow(
                  label: loc.v2SettingsHideStatusBar,
                  description: loc.v2SettingsHideStatusBarDesc,
                  value: AppExperienceController.instance.statusBarHidden,
                  onChanged: (hidden) async {
                    await AppExperienceController.instance.setStatusBarHidden(
                      hidden,
                    );
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}
