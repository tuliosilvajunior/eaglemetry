import 'package:flutter/material.dart';

import '../../capy_ui.dart';
import '../gallery_scaffold.dart';
import '../gallery_shared.dart';

class ChartPinAnnotationGalleryPage extends StatefulWidget {
  const ChartPinAnnotationGalleryPage({super.key});

  @override
  State<ChartPinAnnotationGalleryPage> createState() =>
      _ChartPinAnnotationGalleryPageState();
}

class _ChartPinAnnotationGalleryPageState
    extends State<ChartPinAnnotationGalleryPage> {
  double _dotOffset = 0.35;
  bool _showDot = true;
  bool _extendAbove = true;

  @override
  Widget build(BuildContext context) {
    return GalleryDemoPage(
      title: 'ChartPinAnnotation',
      summary:
          'Vertical rule through a plot with a dot on the pinned reading. '
          'Nothing here animates — the chart moves it every frame.',
      note:
          'The ring around the dot keeps the marker visible on a dark bar. '
          'Pair it with a ChartTooltip placed above the dot.',
      child: GalleryStack(
        children: [
          AppCard(
            title: 'Dot offset',
            subtitle: _dotOffset.toStringAsFixed(2),
            child: TrackSegmentedControl<double>(
              items: const [
                TabItem(value: 0, label: '0'),
                TabItem(value: 0.35, label: '0.35'),
                TabItem(value: 0.7, label: '0.70'),
                TabItem(value: 1, label: '1'),
              ],
              selected: _dotOffset,
              onSelected: (value) => setState(() => _dotOffset = value),
            ),
          ),
          AppCard(
            title: 'Parts',
            child: Column(
              children: [
                SettingToggleRow(
                  label: 'Show the dot',
                  value: _showDot,
                  onChanged: (value) => setState(() => _showDot = value),
                ),
                const SizedBox(height: AppSpacing.x3),
                SettingToggleRow(
                  label: 'Extend the rule above the dot',
                  value: _extendAbove,
                  onChanged: (value) => setState(() => _extendAbove = value),
                ),
              ],
            ),
          ),
          AppCard(
            title: 'On a plot',
            child: SizedBox(
              height: 180,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.control,
                  borderRadius: AppRadii.mdRadius,
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(painter: _FakePlotPainter()),
                    ),
                    Align(
                      alignment: Alignment.center,
                      child: ChartPinAnnotation(
                        height: 180,
                        dotOffset: _dotOffset,
                        showDot: _showDot,
                        extendAboveDot: _extendAbove,
                      ),
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

class _FakePlotPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.energyDraw
      ..strokeWidth = 10
      ..style = PaintingStyle.fill;
    for (var i = 0; i < 8; i++) {
      final x = 16.0 + i * (size.width - 32) / 7;
      final h = 20.0 + (i % 3 + 1) * 28;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x - 5, size.height - h - 8, 10, h),
          const Radius.circular(3),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
