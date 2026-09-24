import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'efficiency_gallery_screen.dart';

/// Standalone entrypoint for the efficiency card harness.
///
/// Kept separate from `lib/main.dart` for the same reason as the other
/// galleries: reviewing a component in progress must never require a dev route
/// in the shipping app.
///
/// ```sh
/// flutter run -d chrome -t packages/capy_ui/lib/gallery/efficiency_main.dart
/// ```
///
/// No telemetry, no channels and no `ThemeController` — the driving is
/// simulated in the screen itself, then reduced by the real `readEfficiency`.
void main() {
  runApp(const EfficiencyGalleryApp());
}

class EfficiencyGalleryApp extends StatelessWidget {
  const EfficiencyGalleryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Efficiency Harness',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const EfficiencyGalleryScreen(),
    );
  }
}
