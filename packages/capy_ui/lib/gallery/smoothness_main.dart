import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'smoothness_gallery_screen.dart';

/// Standalone entrypoint for the driving-smoothness pill harness.
///
/// Kept separate from `lib/main.dart` for the same reason as the other
/// galleries: reviewing a component in progress must never require a dev route
/// in the shipping app.
///
/// ```sh
/// flutter run -d chrome -t packages/capy_ui/lib/gallery/smoothness_main.dart
/// ```
///
/// No telemetry and no channels. The driving is simulated in the screen, then
/// folded by the real `SmoothnessTracker`, so what the pill shows here is what
/// it shows on the car.
void main() {
  runApp(const SmoothnessGalleryApp());
}

class SmoothnessGalleryApp extends StatelessWidget {
  const SmoothnessGalleryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smoothness Harness',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const SmoothnessGalleryScreen(),
    );
  }
}
