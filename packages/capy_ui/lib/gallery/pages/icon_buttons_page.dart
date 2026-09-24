import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class IconButtonsGalleryPage extends StatefulWidget {
  const IconButtonsGalleryPage({super.key});

  @override
  State<IconButtonsGalleryPage> createState() => _IconButtonsGalleryPageState();
}

class _IconButtonsGalleryPageState extends State<IconButtonsGalleryPage> {
  bool _infoSelected = false;
  bool _squareSelected = false;
  int _swaps = 0;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'Icon buttons',
      summary:
          'InfoIconButton is a glyph. SquareIconButton is an action. '
          'Both occupy the 64 px automotive target.',
      note:
          'The selected inverse stays on while the surface the button '
          'opened is visible. Disabled keeps the target and drops the ink.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'InfoIconButton',
            subtitle: 'Unfilled circle in a card header',
            trailing: InfoIconButton(
              selected: _infoSelected,
              onPressed: () => setState(() => _infoSelected = !_infoSelected),
              tooltip: 'About this card',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const InfoIconButton(onPressed: null, tooltip: 'Disabled'),
                    const SizedBox(width: AppSpacing.x3),
                    InfoIconButton(
                      selected: true,
                      onPressed: () {},
                      tooltip: 'Forced selected',
                    ),
                    const SizedBox(width: AppSpacing.x3),
                    InfoIconButton(onPressed: () {}, tooltip: 'Resting'),
                  ],
                ),
                const SizedBox(height: AppSpacing.x4),
                GalleryCaption(
                  _infoSelected
                      ? 'Header button is selected. Tap it again to rest.'
                      : 'Tap the header button to see the inverse fill.',
                ),
              ],
            ),
          ),
          AppCard(
            title: 'SquareIconButton',
            subtitle: 'Filled action beside a metric',
            trailing: SquareIconButton(
              icon: Icons.swap_horiz,
              selected: _squareSelected,
              onPressed: () => setState(() {
                _squareSelected = !_squareSelected;
                _swaps++;
              }),
              tooltip: 'Swap unit',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const SquareIconButton(
                      icon: Icons.settings,
                      onPressed: null,
                      tooltip: 'Disabled',
                    ),
                    const SizedBox(width: AppSpacing.x3),
                    SquareIconButton(
                      icon: Icons.settings,
                      selected: true,
                      onPressed: () {},
                      tooltip: 'Selected',
                    ),
                    const SizedBox(width: AppSpacing.x3),
                    SquareIconButton(
                      icon: Icons.settings,
                      onPressed: () {},
                      tooltip: 'Resting',
                    ),
                    const SizedBox(width: AppSpacing.x3),
                    SquareIconButton(
                      icon: Icons.settings,
                      size: AppSizes.minTouchTarget,
                      onPressed: () {},
                      tooltip: 'Full target size',
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.x4),
                GalleryCaption('Swaps so far: $_swaps'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
