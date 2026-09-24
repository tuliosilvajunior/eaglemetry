import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class SelectableTileGalleryPage extends StatefulWidget {
  const SelectableTileGalleryPage({super.key});

  @override
  State<SelectableTileGalleryPage> createState() =>
      _SelectableTileGalleryPageState();
}

class _SelectableTileGalleryPageState extends State<SelectableTileGalleryPage> {
  int _preset = 2;
  static const _values = ['--', '70%', '85%', '100%'];
  static const _labels = ['Custom', 'Daily', 'Extended', 'Max'];

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'SelectableTile',
      summary:
          'Two-line preset tile from a single-select group. Selected '
          'inverts to the selection fill, never a series colour.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Charge presets',
            subtitle: _labels[_preset],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    for (var i = 0; i < 4; i++) ...[
                      if (i > 0) const SizedBox(width: AppSpacing.x3),
                      Expanded(
                        child: SelectableTile(
                          value: _values[i],
                          label: _labels[i],
                          selected: _preset == i,
                          onPressed: () => setState(() => _preset = i),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.x4),
                const GalleryCaption(
                  'Custom stays `--` until a LimitSlider writes a value that '
                  'is not a named preset.',
                ),
              ],
            ),
          ),
          AppCard(
            title: 'Disabled tile',
            child: SelectableTile(
              value: '50%',
              label: 'Unavailable',
              selected: false,
              onPressed: null,
            ),
          ),
        ],
      ),
    );
  }
}
