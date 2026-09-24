import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class MagnitudeBarsGalleryPage extends StatelessWidget {
  const MagnitudeBarsGalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return GalleryDemoPage(
      title: 'MagnitudeBars',
      summary:
          'Several measured quantities on one scale, each with its number.',
      note:
          'The scale is the largest bar, not the sum. This is a comparison, '
          'not a partition — a reader who takes it for one would read the '
          'longest bar as "all of it". ShareBar is the partition.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Energy balance',
            child: MagnitudeBars(
              bars: [
                MagnitudeBar(
                  value: 3820,
                  label: 'Traction',
                  valueLabel: '3820 Wh',
                  color: colors.energy.draw,
                ),
                MagnitudeBar(
                  value: 540,
                  label: 'Recovered',
                  valueLabel: '540 Wh',
                  color: colors.energy.gain,
                ),
                MagnitudeBar(
                  value: 210,
                  label: 'Other systems',
                  valueLabel: '210 Wh',
                  color: colors.inkSubtle,
                ),
              ],
              footnote: '3.49 kWh net consumed',
            ),
          ),
          AppCard(
            title: 'A quantity that measured zero',
            child: Column(
              children: [
                MagnitudeBars(
                  bars: [
                    MagnitudeBar(
                      value: 1980,
                      label: 'Traction',
                      valueLabel: '1980 Wh',
                      color: colors.energy.draw,
                    ),
                    MagnitudeBar(
                      value: 0,
                      label: 'Recovered',
                      valueLabel: '0 Wh',
                      color: colors.energy.gain,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.x4),
                const GalleryCaption(
                  'It keeps its row and its number, and draws no bar. The row '
                  'is the reading; the bar is only how long it is.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
