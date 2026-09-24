import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class CardStageGalleryPage extends StatefulWidget {
  const CardStageGalleryPage({super.key});

  @override
  State<CardStageGalleryPage> createState() => _CardStageGalleryPageState();
}

class _CardStageGalleryPageState extends State<CardStageGalleryPage>
    with TickerProviderStateMixin {
  late final CardStageController _stage;
  var _stageRow = const CardStageResize([1, 2, 1]);

  @override
  void initState() {
    super.initState();
    _stage = CardStageController(vsync: this);
  }

  @override
  void dispose() {
    _stage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'ExpandableCardStage',
      summary:
          'Two size mechanisms: drag the centre card up to take the row '
          'and sideways to peek its neighbours, and use any card\'s button to '
          'hand it a permanent extra quarter.',
      note:
          'A card collapsed to nothing takes its gutter with it. An edge '
          'with no neighbour resists the peek instead of sliding freely.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Stage',
            subtitle: 'Drag the centre card up, then sideways · buttons resize',
            child: SizedBox(
              height: 260,
              child: ExpandableCardStage(
                stage: _stage,
                expandableIndex: 1,
                expandSemanticsLabel: 'Expand the centre card',
                collapseSemanticsLabel: 'Collapse the centre card',
                slots: [
                  for (var i = 0; i < 3; i++)
                    CardStageSlot(
                      units: _stageRow.units[i],
                      builder: (size) => _StageDemoCard(
                        title: const ['Leading', 'Centre', 'Trailing'][i],
                        size: size,
                        focused: _stageRow.isFocused(i),
                        onToggle: () =>
                            setState(() => _stageRow = _stageRow.toggled(i)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StageDemoCard extends StatelessWidget {
  const _StageDemoCard({
    required this.title,
    required this.size,
    required this.focused,
    required this.onToggle,
  });

  final String title;
  final CardSize size;
  final bool focused;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final roomy = size != CardSize.compact && size != CardSize.hidden;
    return AppCard(
      title: title,
      subtitle: size.name,
      trailing: SquareIconButton(
        icon: focused ? Icons.close_fullscreen : Icons.open_in_full,
        onPressed: onToggle,
        tooltip: focused ? 'Return to its resting width' : 'Take a quarter',
      ),
      child: roomy
          ? const Text(
              'A wider layout, not the same one stretched. The stage '
              'cross-fades between the two halfway through the resize.',
              style: AppText.label,
            )
          : const Align(
              alignment: Alignment.topCenter,
              child: Icon(Icons.crop_square, size: AppSizes.iconLg),
            ),
    );
  }
}
