import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class PillTabBarGalleryPage extends StatefulWidget {
  const PillTabBarGalleryPage({super.key});

  @override
  State<PillTabBarGalleryPage> createState() => _PillTabBarGalleryPageState();
}

enum _Dest { charging, energy, history, settings }

class _PillTabBarGalleryPageState extends State<PillTabBarGalleryPage> {
  _Dest _selected = _Dest.charging;

  static const _items = [
    TabItem(value: _Dest.charging, label: 'Charging'),
    TabItem(value: _Dest.energy, label: 'Energy'),
    TabItem(value: _Dest.history, label: 'History'),
    TabItem(value: _Dest.settings, label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'PillTabBar',
      summary: 'Page-level tabs. One sliding fill, labels invert through it.',
      note:
          'The selected pill is one shape, not a decoration on the item. '
          'A short label still keeps the 64 px target.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Live',
            subtitle: switch (_selected) {
              _Dest.charging => 'Charging',
              _Dest.energy => 'Energy',
              _Dest.history => 'History',
              _Dest.settings => 'Settings',
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PillTabBar<_Dest>(
                  items: _items,
                  selected: _selected,
                  onSelected: (value) => setState(() => _selected = value),
                ),
                const SizedBox(height: AppSpacing.x4),
                const GalleryCaption(
                  'Tap across the row. The fill slides; the letters invert '
                  'only where it covers them.',
                ),
              ],
            ),
          ),
          const AppCard(
            title: 'Two tabs',
            child: PillTabBar<int>(
              items: [
                TabItem(value: 0, label: 'Now'),
                TabItem(value: 1, label: 'Earlier'),
              ],
              selected: 0,
              onSelected: _ignore,
            ),
          ),
          const AppCard(
            title: 'Short labels',
            child: PillTabBar<int>(
              items: [
                TabItem(value: 0, label: 'A'),
                TabItem(value: 1, label: 'B'),
                TabItem(value: 2, label: 'C'),
              ],
              selected: 1,
              onSelected: _ignore,
            ),
          ),
        ],
      ),
    );
  }
}

void _ignore(int _) {}
