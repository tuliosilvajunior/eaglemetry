import 'package:flutter/material.dart';

import '../components/setting_toggle_row.dart';
import '../components/settings_blocks.dart';
import '../components/theme_picker.dart';
import '../components/tip_box.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_palettes.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'app_theme_name.dart';
import 'surface_capabilities.dart';
import '../l10n/capy_ui_localizations.dart';
import '../l10n/capy_ui_localizations_en.dart';

/// Shared, platform-agnostic body for the Settings theme + toggles slices.
///
/// Takes view state ([themeId], [reduceMotion]), intent callbacks
/// ([onThemeChanged], [onReduceMotionChanged]), and surface [capabilities].
/// It never calls [Navigator] and never reads a store directly. The same
/// instance mounts in both the car scaffold and the phone shell via thin
/// adapters.
///
/// `allowKeyboard == false` renders read-only rows plus an explanatory
/// [TipBox]; `true` renders the editable controls. `widthClass` selects
/// compact vs expanded layout spacing.
class SettingsBody extends StatelessWidget {
  const SettingsBody({
    required this.themeId,
    required this.onThemeChanged,
    required this.reduceMotion,
    required this.onReduceMotionChanged,
    required this.capabilities,
    super.key,
  });

  final AppThemeId themeId;
  final ValueChanged<AppThemeId> onThemeChanged;
  final bool reduceMotion;
  final ValueChanged<bool> onReduceMotionChanged;
  final SurfaceCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n =
        Localizations.of<CapyUiL10n>(context, CapyUiL10n) ?? CapyUiL10nEn();
    final allowEdit = capabilities.allowKeyboard;

    final themePicker = ThemePicker(
      selected: themeId,
      onSelected: allowEdit ? onThemeChanged : (_) {},
      nameOf: (id) => appThemeName(id, l10n),
    );

    // When keyboard/input is blocked, ThemePicker is read-only and the
    // body explains why rather than delegating the block to the adapter.
    final pickerSection = allowEdit
        ? themePicker
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Read-only visual: wrap ThemePicker with IgnorePointer so it
              // renders but does not respond. The check mark still shows the
              // current selection.
              IgnorePointer(child: themePicker),
              const SizedBox(height: AppSpacing.x4),
              TipBox(
                label: l10n.settingsThemeReadOnlyLabel,
                message: l10n.settingsThemeReadOnlyMessage,
              ),
            ],
          );

    final togglesRow = SettingToggleRow(
      label: l10n.settingsReduceMotionLabel,
      description: l10n.settingsReduceMotionDesc,
      value: reduceMotion,
      onChanged: allowEdit ? onReduceMotionChanged : null,
    );

    final togglesSection = allowEdit
        ? togglesRow
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              togglesRow,
              const SizedBox(height: AppSpacing.x3),
              TipBox(
                label: l10n.settingsTogglesReadOnlyLabel,
                message: l10n.settingsTogglesReadOnlyMessage,
              ),
            ],
          );

    final colors = AppThemeColors.of(context);
    final appearanceSection = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.settingsAppTheme, style: AppText.bodyStrong),
        const SizedBox(height: AppSpacing.x2),
        Text(
          l10n.settingsThemeDesc,
          style: AppText.caption.copyWith(color: colors.inkMuted),
        ),
        SizedBox(
          height: capabilities.widthClass == SurfaceWidthClass.compact
              ? AppSpacing.x3
              : AppSpacing.x4,
        ),
        pickerSection,
      ],
    );

    final togglesSectionCard = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.settingsTogglesTitle, style: AppText.bodyStrong),
        const SizedBox(height: AppSpacing.x2),
        Text(
          l10n.settingsTogglesDesc,
          style: AppText.caption.copyWith(color: colors.inkMuted),
        ),
        SizedBox(
          height: capabilities.widthClass == SurfaceWidthClass.compact
              ? AppSpacing.x3
              : AppSpacing.x4,
        ),
        togglesSection,
      ],
    );

    // Viewport-reactive: compact is a single column, medium/expanded is a
    // two-column section grid branching only on widthClass, never on isCar.
    return SettingsAdaptiveGrid(
      capabilities: capabilities,
      children: [appearanceSection, togglesSectionCard],
    );
  }
}
