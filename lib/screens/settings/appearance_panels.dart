part of '../settings_screen.dart';

class _ThemePanel extends StatelessWidget {
  const _ThemePanel();

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        final colorScheme = Theme.of(context).colorScheme;
        final selected = <ThemeMode>{ThemeController.instance.themeMode};
        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer,
            border: Border.all(color: colorScheme.outlineVariant),
            borderRadius: AutomotiveRadii.baseRadius,
          ),
          child: Padding(
            padding: AutomotiveSpacing.panelPadding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        loc.settingsAppTheme,
                        style: AutomotiveTextStyles.bodyMd.copyWith(
                          color: colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: AutomotiveSpacing.x0_5),
                      Text(
                        loc.settingsThemeDesc,
                        style: AutomotiveTextStyles.bodyMd.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AutomotiveSpacing.x3),
                SegmentedButton<ThemeMode>(
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: Icon(Icons.dark_mode),
                      label: Text(loc.settingsDark),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: Icon(Icons.light_mode),
                      label: Text(loc.settingsLight),
                    ),
                  ],
                  selected: selected,
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) {
                    final mode = selection.first;
                    HapticFeedback.selectionClick();
                    ThemeController.instance.setThemeMode(mode);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
