import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Material Symbols Outlined `battery_android_frame_alert_24`.
///
/// Flutter's bundled Material Icons font does not contain this newer symbol.
/// The path uses Google's official 24 px Material Symbols geometry.
class BatteryAndroidFrameAlertIcon extends StatelessWidget {
  const BatteryAndroidFrameAlertIcon({
    this.size = AppSizes.iconMd,
    this.color,
    super.key,
  });

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final colors = AppThemeColors.of(context);
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _BatteryAndroidFrameAlertPainter(
          color: color ?? iconTheme.color ?? colors.ink,
        ),
      ),
    );
  }
}

class _BatteryAndroidFrameAlertPainter extends CustomPainter {
  const _BatteryAndroidFrameAlertPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 960, size.height / 960);
    canvas.drawPath(_path, Paint()..color = color);
    canvas.restore();
  }

  Path get _path => Path()
    ..moveTo(840, 660)
    ..quadraticBezierTo(823, 660, 811.5, 648.5)
    ..quadraticBezierTo(800, 637, 800, 620)
    ..quadraticBezierTo(800, 603, 811.5, 591.5)
    ..quadraticBezierTo(823, 580, 840, 580)
    ..quadraticBezierTo(857, 580, 868.5, 591.5)
    ..quadraticBezierTo(880, 603, 880, 620)
    ..quadraticBezierTo(880, 637, 868.5, 648.5)
    ..quadraticBezierTo(857, 660, 840, 660)
    ..close()
    ..moveTo(800, 520)
    ..lineTo(800, 280)
    ..lineTo(880, 280)
    ..lineTo(880, 520)
    ..lineTo(800, 520)
    ..close()
    ..moveTo(160, 720)
    ..quadraticBezierTo(110, 720, 75, 685)
    ..quadraticBezierTo(40, 650, 40, 600)
    ..lineTo(40, 360)
    ..quadraticBezierTo(40, 310, 75, 275)
    ..quadraticBezierTo(110, 240, 160, 240)
    ..lineTo(720, 240)
    ..lineTo(720, 320)
    ..lineTo(160, 320)
    ..quadraticBezierTo(143, 320, 131.5, 331.5)
    ..quadraticBezierTo(120, 343, 120, 360)
    ..lineTo(120, 600)
    ..quadraticBezierTo(120, 617, 131.5, 628.5)
    ..quadraticBezierTo(143, 640, 160, 640)
    ..lineTo(720, 640)
    ..quadraticBezierTo(720, 663, 728.5, 683.5)
    ..quadraticBezierTo(737, 704, 751, 720)
    ..lineTo(160, 720)
    ..close()
    ..moveTo(160, 600)
    ..lineTo(160, 360)
    ..lineTo(720, 360)
    ..lineTo(720, 600)
    ..lineTo(160, 600)
    ..close();

  @override
  bool shouldRepaint(_BatteryAndroidFrameAlertPainter oldDelegate) =>
      oldDelegate.color != color;
}
