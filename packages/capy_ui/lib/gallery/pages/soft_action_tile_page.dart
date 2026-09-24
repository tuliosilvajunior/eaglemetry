import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class SoftActionTileGalleryPage extends StatefulWidget {
  const SoftActionTileGalleryPage({super.key});

  @override
  State<SoftActionTileGalleryPage> createState() =>
      _SoftActionTileGalleryPageState();
}

class _SoftActionTileGalleryPageState extends State<SoftActionTileGalleryPage> {
  int _taps = 0;
  bool _selected = false;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'SoftActionTile',
      summary:
          'Filled grey action row. Semantic colour goes on the glyph, '
          'never on the label or the fill.',
      note:
          'Disabled keeps the fill and drops both glyph and label to '
          'subtle ink. Selected inverts while a panel it opened is visible.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'States',
            subtitle: 'Taps: $_taps',
            child: Column(
              children: [
                SoftActionTile(
                  icon: Icons.electrical_services,
                  label: 'Open charge port',
                  onPressed: () => setState(() => _taps++),
                ),
                const SizedBox(height: AppSpacing.x3),
                SoftActionTile(
                  icon: Icons.flash_off,
                  label: 'Stop charging',
                  iconColor: AppColors.critical,
                  onPressed: () => setState(() => _taps++),
                ),
                const SizedBox(height: AppSpacing.x3),
                const SoftActionTile(
                  icon: Icons.bolt,
                  label: 'Prepare for fast charging (disabled)',
                  onPressed: null,
                ),
                const SizedBox(height: AppSpacing.x3),
                SoftActionTile(
                  icon: Icons.info_outline,
                  label: _selected ? 'Selected while open' : 'Toggle selected',
                  selected: _selected,
                  onPressed: () => setState(() => _selected = !_selected),
                ),
              ],
            ),
          ),
          AppCard(
            title: 'Centered pair',
            child: Row(
              children: [
                Expanded(
                  child: SoftActionTile(
                    icon: Icons.power,
                    label: 'Outlets',
                    centered: true,
                    onPressed: () => setState(() => _taps++),
                  ),
                ),
                const SizedBox(width: AppSpacing.x3),
                Expanded(
                  child: SoftActionTile(
                    label: '48 Amps',
                    centered: true,
                    onPressed: () => setState(() => _taps++),
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
