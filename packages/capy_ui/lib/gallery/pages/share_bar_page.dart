import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class ShareBarGalleryPage extends StatelessWidget {
  const ShareBarGalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return GalleryDemoPage(
      title: 'ShareBar',
      summary: 'How a whole divides, as one pill with a named key under it.',
      note:
          'A partition, not a progress bar. The segments always fill the '
          'pill, because the reading has no remainder to leave. Use '
          'SocSpanBar or CycleBar for a reading that does.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Drive mode',
            child: ShareBar(
              segments: [
                ShareSegment(
                  value: 55,
                  color: colors.energy.gain,
                  label: 'Eco 55%',
                ),
                ShareSegment(
                  value: 35,
                  color: colors.inkSubtle,
                  label: 'Normal 35%',
                ),
                ShareSegment(
                  value: 10,
                  color: colors.energy.draw,
                  label: 'Sport 10%',
                ),
              ],
            ),
          ),
          AppCard(
            title: 'A part that measured nothing',
            child: Column(
              children: [
                ShareBar(
                  segments: [
                    ShareSegment(
                      value: 80,
                      color: colors.energy.gain,
                      label: 'Eco 80%',
                    ),
                    ShareSegment(
                      value: 20,
                      color: colors.inkSubtle,
                      label: 'Normal 20%',
                    ),
                    ShareSegment(
                      value: 0,
                      color: colors.energy.draw,
                      label: 'Sport 0%',
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.x4),
                const GalleryCaption(
                  'The zero part is dropped, and takes its key with it. A '
                  'sliver too thin to see but wide enough to shift its '
                  'neighbours is a lie about a part that was not there.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
