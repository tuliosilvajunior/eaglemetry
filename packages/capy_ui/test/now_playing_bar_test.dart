import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

Widget _host({
  String? title = 'Night Drive',
  String? artist = 'Low Tide',
  int volume = 12,
  int volumeMin = 0,
  int volumeMax = 30,
  ValueChanged<int>? onVolumeChanged,
  ThemeData? theme,
}) {
  return MaterialApp(
    theme: theme ?? AppTheme.light(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 480,
          child: NowPlayingBar(
            title: title,
            artist: artist,
            idleLabel: 'Nothing playing',
            volume: volume,
            volumeMin: volumeMin,
            volumeMax: volumeMax,
            onVolumeChanged: onVolumeChanged,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('shows the title and the artist', (tester) async {
    await tester.pumpWidget(_host(onVolumeChanged: (_) {}));

    expect(find.text('Night Drive'), findsOneWidget);
    expect(find.text('Low Tide'), findsOneWidget);
  });

  testWidgets('a missing track shows the idle label, not a dash', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(title: null, artist: null, onVolumeChanged: (_) {}),
    );

    expect(find.text('Nothing playing'), findsOneWidget);
    expect(find.text('Night Drive'), findsNothing);
  });

  testWidgets('at volume zero the artwork sits in the leading cap', (
    tester,
  ) async {
    await tester.pumpWidget(_host(volume: 0, onVolumeChanged: (_) {}));

    final bar = tester.getRect(find.byKey(const Key('now-playing-bar')));
    final art = tester.getRect(find.byKey(const Key('now-playing-artwork')));
    expect(art.center.dx, closeTo(bar.left + bar.height / 2, 1.5));
  });

  testWidgets('the volume icon sits in the trailing cap', (tester) async {
    await tester.pumpWidget(_host(onVolumeChanged: (_) {}));

    final bar = tester.getRect(find.byKey(const Key('now-playing-bar')));
    final icon = tester.getRect(
      find.byKey(const Key('now-playing-volume-icon')),
    );
    expect(icon.center.dx, closeTo(bar.right - bar.height / 2, 1.5));
  });

  testWidgets('a new track replaces the title', (tester) async {
    var title = 'Night Drive';
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Column(
                children: [
                  NowPlayingBar(
                    title: title,
                    artist: 'Low Tide',
                    idleLabel: 'Nothing playing',
                    volume: 12,
                    volumeMax: 30,
                    onVolumeChanged: (_) {},
                  ),
                  TextButton(
                    onPressed: () => setState(() => title = 'Coastal'),
                    child: const Text('Next'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    expect(find.text('Night Drive'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Coastal'), findsOneWidget);
    expect(find.text('Night Drive'), findsNothing);
  });

  testWidgets('meets the automotive touch minimum', (tester) async {
    await tester.pumpWidget(_host(onVolumeChanged: (_) {}));

    expect(
      tester.getSize(find.byKey(const Key('now-playing-bar'))).height,
      greaterThanOrEqualTo(64),
    );
  });

  testWidgets('a sideways drag steps volume and does not open a tooltip', (
    tester,
  ) async {
    var volume = 12;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return _host(
            volume: volume,
            onVolumeChanged: (next) => setState(() => volume = next),
          );
        },
      ),
    );

    await tester.drag(
      find.byKey(const Key('now-playing-bar')),
      const Offset(120, 0),
    );
    await tester.pumpAndSettle();

    expect(volume, greaterThan(12));
    expect(find.text('Volume'), findsNothing);
  });

  testWidgets('a tap does not change the volume', (tester) async {
    var volume = 12;
    await tester.pumpWidget(
      _host(volume: volume, onVolumeChanged: (next) => volume = next),
    );

    await tester.tap(find.byKey(const Key('now-playing-bar')));
    await tester.pumpAndSettle();

    expect(volume, 12);
    expect(find.text('Volume'), findsNothing);
  });

  testWidgets('a null callback leaves the fill and ignores a drag', (
    tester,
  ) async {
    await tester.pumpWidget(_host());

    expect(find.byKey(const Key('now-playing-volume-fill')), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('now-playing-bar')),
      const Offset(120, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('Volume'), findsNothing);
  });

  testWidgets('the pill follows the theme, not the climate-bar constants', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(theme: AppTheme.light(), onVolumeChanged: (_) {}),
    );
    var decoration = tester
        .widget<AnimatedContainer>(find.byKey(const Key('now-playing-bar')))
        .decoration;
    expect(decoration, isA<BoxDecoration>());
    expect((decoration as BoxDecoration).color, AppColors.control);

    await tester.pumpWidget(
      _host(theme: AppTheme.dark(), onVolumeChanged: (_) {}),
    );
    await tester.pumpAndSettle();
    decoration = tester
        .widget<AnimatedContainer>(find.byKey(const Key('now-playing-bar')))
        .decoration;
    expect((decoration! as BoxDecoration).color, AppThemeColors.dark.control);
    expect(
      (decoration as BoxDecoration).color,
      isNot(AppColors.climatePillSurface),
    );
  });
}
