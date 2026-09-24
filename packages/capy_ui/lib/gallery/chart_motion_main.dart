import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'chart_motion_gallery_screen.dart';

/// Standalone entrypoint for the chart-motion harness.
///
/// Separate from `gallery_main.dart` because the two answer different
/// questions: the gallery calibrates fixed states side by side, this one shows
/// [EnergyBarChart] while its numbers change.
///
/// ```sh
/// flutter run -d chrome -t packages/capy_ui/lib/gallery/chart_motion_main.dart
/// ```
///
/// No telemetry, no channels, no `ThemeController` — nothing here touches app
/// state.
void main() {
  runApp(const ChartMotionApp());
}

class ChartMotionApp extends StatelessWidget {
  const ChartMotionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chart motion',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const ChartMotionGalleryScreen(),
    );
  }
}
