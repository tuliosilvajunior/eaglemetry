import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class TextTabBarGalleryPage extends StatefulWidget {
  const TextTabBarGalleryPage({super.key});

  @override
  State<TextTabBarGalleryPage> createState() => _TextTabBarGalleryPageState();
}

enum _CardTab { limit, graph, schedule }

class _TextTabBarGalleryPageState extends State<TextTabBarGalleryPage> {
  _CardTab _selected = _CardTab.limit;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'TextTabBar',
      summary:
          'In-card tabs. No fill. The selected label is ink, the rest '
          'are subtle.',
      note:
          'A fill here would compete with the card. Each item keeps the '
          '64 px target even when the label is one letter.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Live',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextTabBar<_CardTab>(
                  items: const [
                    TabItem(value: _CardTab.limit, label: 'Limit'),
                    TabItem(value: _CardTab.graph, label: 'Graph'),
                    TabItem(value: _CardTab.schedule, label: 'Schedule'),
                  ],
                  selected: _selected,
                  onSelected: (value) => setState(() => _selected = value),
                ),
                const SizedBox(height: AppSpacing.x6),
                Text(switch (_selected) {
                  _CardTab.limit => 'Charge-limit controls would sit here.',
                  _CardTab.graph => 'The session graph would sit here.',
                  _CardTab.schedule => 'Departure schedule would sit here.',
                }, style: AppText.body),
              ],
            ),
          ),
          const AppCard(
            title: 'Short labels',
            child: TextTabBar<int>(
              items: [
                TabItem(value: 0, label: 'I'),
                TabItem(value: 1, label: 'II'),
                TabItem(value: 2, label: 'III'),
              ],
              selected: 0,
              onSelected: _ignore,
            ),
          ),
        ],
      ),
    );
  }
}

void _ignore(int _) {}
