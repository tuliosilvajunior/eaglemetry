import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class AnchoredTooltipGalleryPage extends StatefulWidget {
  const AnchoredTooltipGalleryPage({super.key});

  @override
  State<AnchoredTooltipGalleryPage> createState() =>
      _AnchoredTooltipGalleryPageState();
}

class _AnchoredTooltipGalleryPageState
    extends State<AnchoredTooltipGalleryPage> {
  AnchoredTooltipSide _side = AnchoredTooltipSide.auto;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'AnchoredTooltip',
      summary:
          'Owns the anchor, the modal route, and the open state. The '
          'trigger stays selected while the panel is visible.',
      note:
          'An explicit side flips when it cannot contain the full panel and '
          'the opposite side can. auto picks the side with more room.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Preferred side',
            child: TrackSegmentedControl<AnchoredTooltipSide>(
              items: const [
                TabItem(value: AnchoredTooltipSide.auto, label: 'Auto'),
                TabItem(value: AnchoredTooltipSide.left, label: 'Left'),
                TabItem(value: AnchoredTooltipSide.right, label: 'Right'),
              ],
              selected: _side,
              onSelected: (value) => setState(() => _side = value),
            ),
          ),
          AppCard(
            title: 'Charge-limit guidance',
            trailing: AnchoredTooltipTrigger(
              side: _side,
              caretAlignment: 0.08,
              anchorInsets: const EdgeInsets.all(AppSpacing.x4),
              barrierLabel: 'Close charge limit information',
              tooltipBuilder: (context) => const InformationTooltipPanel(
                title: 'Which charge limit should I pick?',
                children: [
                  InformationCard(
                    value: '70%',
                    description:
                        'For daily driving and shorter charging times.',
                  ),
                  InformationCard(
                    value: '85%',
                    description: 'Travel an extended distance on one charge.',
                  ),
                  InformationCard(
                    value: '100%',
                    description: 'For max range and longer charging times.',
                  ),
                ],
              ),
              builder: (context, isOpen, open) => InfoIconButton(
                selected: isOpen,
                onPressed: open,
                tooltip: 'About charge limits',
              ),
            ),
            child: const GalleryCaption(
              'Tap the header info button. It stays inverse until the panel '
              'closes.',
            ),
          ),
        ],
      ),
    );
  }
}
