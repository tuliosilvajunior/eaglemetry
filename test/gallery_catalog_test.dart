import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/gallery/gallery_catalog.dart';
import 'package:capy_ui/gallery/gallery_home.dart';
import 'package:capy_ui/gallery/gallery_main.dart';
import 'package:capy_ui/capy_ui.dart';

void main() {
  test('every catalog id is unique and route-safe', () {
    final ids = galleryEntries.map((entry) => entry.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    for (final id in ids) {
      expect(id, isNot(contains(' ')));
      expect(id, isNot(startsWith('/')));
    }
  });

  testWidgets('the catalog lists every entry', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const GalleryApp());
    await tester.pump();

    expect(find.byType(GalleryHome), findsOneWidget);
    for (final entry in galleryEntries) {
      await tester.ensureVisible(find.text(entry.name));
      expect(find.text(entry.name), findsWidgets);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('each component page lays out on an automotive viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final entry in galleryEntries) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(builder: entry.builder),
        ),
      );
      // Breathing banners and harness timers keep running. One frame is
      // enough to prove the page builds.
      await tester.pump(AppMotion.slow);
      expect(tester.takeException(), isNull, reason: entry.id);
    }
  });
}
