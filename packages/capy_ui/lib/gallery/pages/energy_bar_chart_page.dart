import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class EnergyBarChartGalleryPage extends StatefulWidget {
  const EnergyBarChartGalleryPage({super.key});

  @override
  State<EnergyBarChartGalleryPage> createState() =>
      _EnergyBarChartGalleryPageState();
}

class _EnergyBarChartGalleryPageState extends State<EnergyBarChartGalleryPage> {
  int? _energySelection = 5;
  int? _chargeSelection = 7;
  int _energyDemoAdds = 0;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'EnergyBarChart',
      summary:
          'Drive energy on the left, charge energy on the right. One '
          'component, two palettes and two bucket widths.',
      note:
          'Add bar completes one slot at the resolution currently on '
          'screen. When the window fills, the series rebuckets. Open Chart '
          'motion from the catalog to watch a live bar travel.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Energy use',
            subtitle: 'Live bucket transition demo',
            trailing: SizedBox(
              width: 164,
              child: SoftActionTile(
                label: 'Add bar',
                icon: Icons.add,
                centered: true,
                onPressed: () => setState(() => _energyDemoAdds++),
              ),
            ),
            child: SizedBox(
              height: 304,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final slots = AppSizes.chartBarProfile.slotsIn(
                    constraints.maxWidth - AppSizes.chartAxisGutter,
                  );
                  final timeline = _energyDemoTimeline(slots);
                  final buckets = _energyDemoBuckets(
                    elapsedMinutes: timeline.elapsedMinutes,
                    bucketMinutes: timeline.bucketMinutes,
                  );
                  final ceiling = 3.6 * timeline.bucketMinutes;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${timeline.bucketMinutes} min buckets · '
                        '${buckets.length}/$slots bars',
                        style: AppText.caption.copyWith(
                          color: AppColors.inkSubtle,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.x2),
                      Expanded(
                        child: EnergyBarChart(
                          slotCount: slots,
                          xTicks: _mockTimeTicks(
                            slotCount: slots,
                            startMinutes: 7 * 60,
                            bucketMinutes: timeline.bucketMinutes,
                          ),
                          bars: [
                            for (final bucket in buckets)
                              EnergyBar(
                                id: (
                                  bucket.startMinute,
                                  timeline.bucketMinutes,
                                ),
                                value: bucket.traction,
                                base: bucket.auxiliary,
                                counter: -bucket.regeneration,
                              ),
                          ],
                          ticks: [
                            ChartTick(
                              value: ceiling,
                              label: ceiling.toStringAsFixed(1),
                            ),
                            ChartTick(
                              value: ceiling * 2 / 3,
                              label: (ceiling * 2 / 3).toStringAsFixed(1),
                            ),
                            ChartTick(
                              value: ceiling / 3,
                              label: (ceiling / 3).toStringAsFixed(1),
                            ),
                            const ChartTick(value: 0, label: '0.0'),
                            ChartTick(
                              value: -1.2 * timeline.bucketMinutes,
                              label:
                                  '+${(1.2 * timeline.bucketMinutes).toStringAsFixed(1)}',
                            ),
                          ],
                          selectedIndex: _energySelection,
                          onSelected: (value) =>
                              setState(() => _energySelection = value),
                          tooltipBuilder: (context, index) {
                            final bucket = buckets[index];
                            final from = 7 * 60 + bucket.startMinute;
                            final to = 7 * 60 + bucket.endMinute;
                            return ChartTooltip(
                              side: ChartTooltipSide.none,
                              value: (bucket.traction + bucket.auxiliary)
                                  .toStringAsFixed(1),
                              unit: 'kWh',
                              rows: [
                                if (bucket.regeneration > 0)
                                  ChartTooltipRow(
                                    label:
                                        '+${bucket.regeneration.toStringAsFixed(1)} kWh',
                                    color: AppColors.energyGain,
                                  ),
                                ChartTooltipRow(
                                  label:
                                      '${_mockTimeLabel(from)}–${_mockTimeLabel(to)}',
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
          AppCard(
            title: 'Graph',
            subtitle: 'Active charge session',
            child: SizedBox(
              height: 300,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const powers = [
                    2.0,
                    4.8,
                    7.6,
                    9.4,
                    10.3,
                    10.8,
                    10.6,
                    10.4,
                    10.1,
                    9.8,
                    9.4,
                    9.0,
                  ];
                  const profile = AppSizes.chartDenseBarProfile;
                  final slots = profile.slotsIn(
                    constraints.maxWidth - AppSizes.chartAxisGutter,
                  );
                  return EnergyBarChart(
                    positiveColor: AppColors.energyGain,
                    slotCount: slots,
                    profile: profile,
                    xTicks: _mockTimeTicks(
                      slotCount: slots,
                      startMinutes: 8 * 60,
                      bucketMinutes: 15,
                    ),
                    bars: [
                      for (var i = 0; i < powers.length; i++)
                        EnergyBar(
                          value: powers[i],
                          state: i < 7
                              ? EnergyBarState.actual
                              : i == 7
                              ? EnergyBarState.now
                              : EnergyBarState.projected,
                        ),
                    ],
                    ticks: const [
                      ChartTick(value: 11, label: '11'),
                      ChartTick(value: 5.5, label: '5.5'),
                      ChartTick(value: 0, label: '0'),
                    ],
                    overlay: const [0, 4.0, 7.5, 9.6, 10.5, 10.8, 10.8],
                    selectedIndex: _chargeSelection,
                    onSelected: (value) =>
                        setState(() => _chargeSelection = value),
                    tooltipBuilder: (context, index) => ChartTooltip(
                      side: ChartTooltipSide.none,
                      value: '${(31 + index).clamp(0, 100)}',
                      unit: '%',
                      rows: [
                        ChartTooltipRow(
                          label: '${powers[index].toStringAsFixed(1)} kW',
                        ),
                        ChartTooltipRow(
                          label: _mockTimeLabel(8 * 60 + index * 15),
                        ),
                      ],
                    ),
                    cornerCaption: 'Charge limit 65%',
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  ({int elapsedMinutes, int bucketMinutes}) _energyDemoTimeline(int slots) {
    if (slots <= 0) return (elapsedMinutes: 0, bucketMinutes: 1);
    var elapsedMinutes = (slots - 3).clamp(1, slots);
    var bucketMinutes = _liveDemoBucketMinutes(elapsedMinutes, slots);
    for (var step = 0; step < _energyDemoAdds; step++) {
      elapsedMinutes += bucketMinutes;
      bucketMinutes = _liveDemoBucketMinutes(elapsedMinutes, slots);
    }
    return (elapsedMinutes: elapsedMinutes, bucketMinutes: bucketMinutes);
  }

  int _liveDemoBucketMinutes(int elapsedMinutes, int slots) {
    var width = chooseEnergyBucketWidth(
      span: Duration(minutes: elapsedMinutes),
      capacity: slots,
    );
    if (elapsedMinutes >= width.inMinutes * slots) {
      width = nextEnergyBucketWidth(width);
    }
    return width.inMinutes;
  }

  List<_EnergyDemoBucket> _energyDemoBuckets({
    required int elapsedMinutes,
    required int bucketMinutes,
  }) {
    const traction = [
      1.4,
      1.9,
      2.6,
      1.8,
      2.1,
      2.8,
      1.6,
      0.2,
      0.0,
      0.0,
      1.2,
      1.8,
    ];
    const auxiliary = [
      0.24,
      0.24,
      0.24,
      0.24,
      0.24,
      0.24,
      0.24,
      0.18,
      0.18,
      0.18,
      0.24,
      0.24,
    ];
    const regeneration = [
      0.0,
      0.0,
      0.0,
      0.1,
      0.0,
      0.0,
      0.3,
      0.7,
      1.0,
      0.6,
      0.0,
      0.0,
    ];
    if (elapsedMinutes <= 0) return const [];
    final count = (elapsedMinutes / bucketMinutes).ceil();
    return [
      for (var index = 0; index < count; index++)
        () {
          final start = index * bucketMinutes;
          final end = (start + bucketMinutes).clamp(0, elapsedMinutes);
          double sum(List<double> pattern) => [
            for (var minute = start; minute < end; minute++)
              pattern[minute % pattern.length],
          ].fold(0.0, (total, value) => total + value);
          return _EnergyDemoBucket(
            startMinute: start,
            endMinute: end,
            traction: sum(traction),
            auxiliary: sum(auxiliary),
            regeneration: sum(regeneration),
          );
        }(),
    ];
  }

  List<ChartXTick> _mockTimeTicks({
    required int slotCount,
    required int startMinutes,
    required int bucketMinutes,
  }) {
    if (slotCount <= 0) return const [];
    return buildChartXTimeTicks(
      domainStart: DateTime(2026, 1, 1).add(Duration(minutes: startMinutes)),
      bucketWidth: Duration(minutes: bucketMinutes),
      slotCount: slotCount,
      labelBuilder: (value) => _mockTimeLabel(value.hour * 60 + value.minute),
    );
  }

  String _mockTimeLabel(int totalMinutes) {
    final minutesInDay = totalMinutes % (24 * 60);
    final hour24 = minutesInDay ~/ 60;
    final minute = minutesInDay % 60;
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final suffix = hour24 < 12 ? 'AM' : 'PM';
    return minute == 0
        ? '$hour12 $suffix'
        : '$hour12:${minute.toString().padLeft(2, '0')} $suffix';
  }
}

class _EnergyDemoBucket {
  const _EnergyDemoBucket({
    required this.startMinute,
    required this.endMinute,
    required this.traction,
    required this.auxiliary,
    required this.regeneration,
  });

  final int startMinute;
  final int endMinute;
  final double traction;
  final double auxiliary;
  final double regeneration;
}
