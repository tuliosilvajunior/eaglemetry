import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class SettingsBlocksGalleryPage extends StatefulWidget {
  const SettingsBlocksGalleryPage({super.key});

  @override
  State<SettingsBlocksGalleryPage> createState() =>
      _SettingsBlocksGalleryPageState();
}

class _SettingsBlocksGalleryPageState extends State<SettingsBlocksGalleryPage> {
  bool _toggle1 = true;
  bool _toggle2 = false;
  SurfaceWidthClass _widthClass = SurfaceWidthClass.compact;

  @override
  Widget build(BuildContext context) {
    final capabilities = SurfaceCapabilities(
      widthClass: _widthClass,
      supportsSelection: _widthClass == SurfaceWidthClass.expanded,
      inputMode: _widthClass == SurfaceWidthClass.expanded
          ? SurfaceInputMode.rotary
          : SurfaceInputMode.touch,
      allowKeyboard: true,
      density: _widthClass == SurfaceWidthClass.compact
          ? SurfaceDensity.compact
          : SurfaceDensity.comfortable,
    );

    return GalleryDemoPage(
      title: 'Settings Blocks',
      summary:
          'Settings scaffolding primitives: SettingsEntry, SettingsRows, SettingsSections, and SettingsAdaptiveGrid.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Width Class Switcher',
            child: TrackSegmentedControl<SurfaceWidthClass>(
              items: const [
                TabItem(
                  value: SurfaceWidthClass.compact,
                  label: 'Compact (Single Col)',
                ),
                TabItem(
                  value: SurfaceWidthClass.medium,
                  label: 'Medium (2-Col Grid)',
                ),
                TabItem(
                  value: SurfaceWidthClass.expanded,
                  label: 'Expanded (2-Col Grid)',
                ),
              ],
              selected: _widthClass,
              onSelected: (val) => setState(() => _widthClass = val),
            ),
          ),
          AppCard(
            title: 'SettingsAdaptiveGrid Demo',
            subtitle:
                'Adapts columns according to SurfaceCapabilities.widthClass',
            child: SettingsAdaptiveGrid(
              capabilities: capabilities,
              children: [
                AppCard(
                  title: 'Section A',
                  child: SettingsRows(
                    children: [
                      SettingsEntry(
                        title: 'Setting Item 1',
                        description: 'Explanation for setting item 1',
                        child: SettingToggleRow(
                          label: 'Enable Feature 1',
                          value: _toggle1,
                          onChanged: (v) => setState(() => _toggle1 = v),
                        ),
                      ),
                      SettingsEntry(
                        title: 'Setting Item 2',
                        description: 'Explanation for setting item 2',
                        child: SettingToggleRow(
                          label: 'Enable Feature 2',
                          value: _toggle2,
                          onChanged: (v) => setState(() => _toggle2 = v),
                        ),
                      ),
                    ],
                  ),
                ),
                const AppCard(
                  title: 'Section B',
                  child: SettingsEntry(
                    title: 'Storage usage',
                    description:
                        'Local sqlite database archive size on this device.',
                    child: Text('3.66 MB used'),
                  ),
                ),
              ],
            ),
          ),
          const AppCard(
            title: 'SettingsSections (Linear Stack)',
            child: SettingsSections(
              children: [
                Text('First linear section'),
                Text('Second linear section'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
