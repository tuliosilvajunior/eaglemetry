import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class SeriesTraceGalleryPage extends StatelessWidget {
  const SeriesTraceGalleryPage({super.key});

  static List<SeriesTracePoint> _hill({bool withGap = false}) {
    return [
      for (var i = 0; i < 60; i++)
        SeriesTracePoint(
          position: i / 59,
          value: withGap && i > 24 && i < 34
              ? null
              : 700 + 60 * math.sin(i / 9) + 25 * math.sin(i / 3.1),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return GalleryDemoPage(
      title: 'SeriesTrace',
      summary: 'One measured quantity across a session, over its own range.',
      note:
          'The axis is the data, not a fixed scale: a flat drive and a '
          'mountain drive are different questions. The two labels are what '
          'stop a flat trace reading as a dramatic one.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Altitude',
            child: SeriesTrace(
              points: _hill(),
              minLabel: '635 m',
              maxLabel: '785 m',
            ),
          ),
          AppCard(
            title: 'An interval the car did not report',
            child: Column(
              children: [
                SeriesTrace(
                  points: _hill(withGap: true),
                  minLabel: '635 m',
                  maxLabel: '785 m',
                  color: colors.energy.focus,
                ),
                const SizedBox(height: AppSpacing.x4),
                const GalleryCaption(
                  'The line breaks. Joining across it would invent a slope '
                  'that nothing measured.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
