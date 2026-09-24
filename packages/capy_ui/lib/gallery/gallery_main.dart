import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../l10n/capy_ui_localizations.dart';
import 'gallery_catalog.dart';
import 'gallery_home.dart';

/// Standalone entrypoint for the design-system gallery.
///
/// Kept separate from `lib/main.dart` so reviewing the new components never
/// requires wiring a dev route into the shipping app:
///
/// ```sh
/// flutter run -d chrome -t packages/capy_ui/lib/gallery/gallery_main.dart
/// ```
///
/// The home screen is a catalog. Each tile opens one component's demonstration
/// page. No telemetry, no channels and no `ThemeController` — nothing here
/// touches app state.
void main() {
  runApp(const GalleryApp());
}

class GalleryApp extends StatelessWidget {
  const GalleryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UI Gallery',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      localizationsDelegates: CapyUiL10n.localizationsDelegates,
      supportedLocales: CapyUiL10n.supportedLocales,
      initialRoute: '/',
      onGenerateRoute: (settings) {
        final name = settings.name ?? '/';
        if (name == '/') {
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const GalleryHome(),
          );
        }
        final id = name.startsWith('/') ? name.substring(1) : name;
        final entry = galleryEntryById(id);
        if (entry == null) {
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const GalleryHome(),
          );
        }
        return MaterialPageRoute<void>(
          settings: settings,
          builder: entry.builder,
        );
      },
    );
  }
}
