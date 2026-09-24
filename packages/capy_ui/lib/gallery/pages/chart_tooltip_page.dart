import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class ChartTooltipGalleryPage extends StatefulWidget {
  const ChartTooltipGalleryPage({super.key});

  @override
  State<ChartTooltipGalleryPage> createState() =>
      _ChartTooltipGalleryPageState();
}

class _ChartTooltipGalleryPageState extends State<ChartTooltipGalleryPage> {
  ChartTooltipSide _side = ChartTooltipSide.bottom;
  double _caret = 0.5;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'ChartTooltip',
      summary:
          'Callout bubble for a pinned reading. Caret sides and alignment '
          'are the whole surface.',
      note:
          'A caret pushed to the far end stops at the flat part of the '
          'edge instead of climbing the corner. The dark panel is so the one '
          'dark surface in the system can be judged against a control.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Side',
            child: TrackSegmentedControl<ChartTooltipSide>(
              items: const [
                TabItem(value: ChartTooltipSide.bottom, label: 'Bottom'),
                TabItem(value: ChartTooltipSide.top, label: 'Top'),
                TabItem(value: ChartTooltipSide.left, label: 'Left'),
                TabItem(value: ChartTooltipSide.right, label: 'Right'),
                TabItem(value: ChartTooltipSide.none, label: 'None'),
              ],
              selected: _side,
              onSelected: (value) => setState(() => _side = value),
            ),
          ),
          AppCard(
            title: 'Caret alignment',
            subtitle: _caret.toStringAsFixed(2),
            child: TrackSegmentedControl<double>(
              items: const [
                TabItem(value: 0, label: '0'),
                TabItem(value: 0.5, label: '0.5'),
                TabItem(value: 1, label: '1'),
              ],
              selected: _caret,
              onSelected: (value) => setState(() => _caret = value),
            ),
          ),
          AppCard(
            title: 'Live',
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.x6),
              decoration: const BoxDecoration(
                color: AppColors.control,
                borderRadius: AppRadii.mdRadius,
              ),
              child: Center(
                child: ChartTooltip(
                  title: '14:00',
                  value: '10.8',
                  unit: 'kW',
                  side: _side,
                  caretAlignment: _caret,
                  rows: const [
                    ChartTooltipRow(
                      label: 'Consumed',
                      value: '55.6 kWh',
                      color: AppColors.energyDraw,
                    ),
                    ChartTooltipRow(
                      label: 'Regen',
                      value: '12.2 kWh',
                      color: AppColors.energyGain,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const AppCard(
            title: 'Every caret side',
            child: ColoredBox(
              color: AppColors.control,
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.x6),
                child: Column(
                  children: [
                    ChartTooltip(
                      title: '14:00',
                      value: '10.8',
                      unit: 'kW',
                      rows: [
                        ChartTooltipRow(
                          label: 'Consumed',
                          value: '55.6 kWh',
                          color: AppColors.energyDraw,
                        ),
                        ChartTooltipRow(
                          label: 'Regen',
                          value: '12.2 kWh',
                          color: AppColors.energyGain,
                        ),
                      ],
                    ),
                    SizedBox(height: AppSpacing.x5),
                    ChartTooltip(
                      value: '2.18',
                      unit: 'mi/kWh',
                      side: ChartTooltipSide.top,
                      caretAlignment: -1,
                    ),
                    SizedBox(height: AppSpacing.x5),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ChartTooltip(
                          value: '48%',
                          side: ChartTooltipSide.right,
                        ),
                        SizedBox(width: AppSpacing.x3),
                        ChartTooltip(value: '48%', side: ChartTooltipSide.left),
                      ],
                    ),
                    SizedBox(height: AppSpacing.x5),
                    ChartTooltip(
                      title: 'No caret',
                      value: '75.3',
                      unit: 'mi',
                      side: ChartTooltipSide.none,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
