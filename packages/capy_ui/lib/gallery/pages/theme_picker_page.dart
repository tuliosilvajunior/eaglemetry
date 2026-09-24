import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class ThemePickerGalleryPage extends StatefulWidget {
  const ThemePickerGalleryPage({super.key});

  @override
  State<ThemePickerGalleryPage> createState() => _ThemePickerGalleryPageState();
}

class _ThemePickerGalleryPageState extends State<ThemePickerGalleryPage> {
  AppThemeId _selected = AppThemeId.light;

  String _nameOf(AppThemeId id) => switch (id) {
    AppThemeId.light => 'Light',
    AppThemeId.dark => 'Dark',
    AppThemeId.midnight => 'Midnight',
    AppThemeId.sepia => 'Sepia',
    AppThemeId.nordic => 'Nordic',
    AppThemeId.daylight => 'Daylight',
    AppThemeId.tokyoNeon => 'Tokyo Neon',
    AppThemeId.sunsetDrive => 'Sunset Drive',
    AppThemeId.bubblegum => 'Bubblegum',
  };

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: AppTheme.forId(_selected),
      child: GalleryDemoPage(
        title: 'ThemePicker',
        summary:
            'Single-select grid of themes. Each tile paints itself in '
            'the palette it offers, so the choice is made by looking.',
        note:
            'The ring around the selected tile uses the current theme, not '
            'the offered one. Switching here restyles this page only.',
        child: GalleryStack(
          children: [
            AppCard(
              title: 'Catalogue',
              subtitle: _nameOf(_selected),
              child: ThemePicker(
                selected: _selected,
                onSelected: (id) => setState(() => _selected = id),
                nameOf: _nameOf,
              ),
            ),
            AppCard(
              title: 'What the pick produces',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MetricValue(value: '202', unit: 'km', size: MetricSize.lg),
                  const SizedBox(height: AppSpacing.x4),
                  SoftActionTile(
                    icon: Icons.bolt,
                    label: 'A control on this canvas',
                    onPressed: () {},
                  ),
                  const SizedBox(height: AppSpacing.x4),
                  const GalleryCaption(
                    'Gain and draw never swap roles. Only the neutrals, and '
                    'the three expressive ramps, change.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
