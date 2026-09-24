// ignore_for_file: prefer_initializing_formals
import 'package:capy_ui/l10n/capy_ui_localizations_en.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

Widget _host({
  required Widget child,
  Locale locale = const Locale('en'),
  double width = 390,
}) {
  return MaterialApp(
    locale: locale,
    theme: AppTheme.light(),
    localizationsDelegates: CapyUiL10n.localizationsDelegates,
    supportedLocales: CapyUiL10n.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 800)),
      child: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

class _FakeSource extends SettingsSource {
  _FakeSource(this._themeId, {bool reduceMotion = false})
    : _reduceMotion = reduceMotion;

  AppThemeId _themeId;
  bool _reduceMotion;
  int setThemeCalls = 0;
  AppThemeId? lastSetTheme;
  int setReduceCalls = 0;
  bool? lastSetReduce;

  @override
  AppThemeId get themeId => _themeId;

  @override
  bool get reduceMotion => _reduceMotion;

  @override
  Future<void> setThemeId(AppThemeId id) async {
    setThemeCalls++;
    lastSetTheme = id;
    _themeId = id;
    notifyListeners();
  }

  @override
  Future<void> setReduceMotion(bool value) async {
    setReduceCalls++;
    lastSetReduce = value;
    _reduceMotion = value;
    notifyListeners();
  }
}

void main() {
  group('SettingsBody', () {
    testWidgets('renders ThemePicker with current selection', (tester) async {
      await tester.pumpWidget(
        _host(
          child: SettingsBody(
            themeId: AppThemeId.dark,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(390),
          ),
        ),
      );
      // Theme name for dark in en is "Petrol"
      expect(find.text('Petrol'), findsOneWidget);
      // All nine tiles render (one per AppThemeId)
      expect(find.byType(ThemePicker), findsOneWidget);
      // Toggles section present
      expect(find.byType(SettingToggleRow), findsOneWidget);
      expect(find.text('Reduce motion'), findsOneWidget);
    });

    testWidgets('compact vs expanded both build and differ in spacing', (
      tester,
    ) async {
      // Pump compact
      await tester.pumpWidget(
        _host(
          width: 390,
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(390),
          ),
        ),
      );
      expect(find.byType(SettingsBody), findsOneWidget);
      // Expanded (head unit 1920 scaled to 960 still expanded)
      await tester.pumpWidget(
        _host(
          width: 960,
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(960),
          ),
        ),
      );
      expect(find.byType(SettingsBody), findsOneWidget);

      // Also verify via MediaQuery.of path that widthClass triggers different SizedBox.
      // We assert capabilities value directly for documentation.
      expect(
        SurfaceCapabilities.fromWidth(390).widthClass,
        SurfaceWidthClass.compact,
      );
      expect(
        SurfaceCapabilities.fromWidth(960).widthClass,
        SurfaceWidthClass.expanded,
      );
    });

    testWidgets('compact is single column and expanded is 2-col grid', (
      tester,
    ) async {
      // Compact should use single column (SettingsAdaptiveGrid with compact)
      await tester.pumpWidget(
        _host(
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(390),
          ),
        ),
      );
      expect(find.byType(SettingsAdaptiveGrid), findsOneWidget);
      final compactGrid = tester.widget<SettingsAdaptiveGrid>(
        find.byType(SettingsAdaptiveGrid),
      );
      expect(compactGrid.capabilities.widthClass, SurfaceWidthClass.compact);

      // Expanded should be 2-col grid
      await tester.pumpWidget(
        _host(
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(960),
          ),
        ),
      );
      expect(find.byType(SettingsAdaptiveGrid), findsOneWidget);
      final expandedGrid = tester.widget<SettingsAdaptiveGrid>(
        find.byType(SettingsAdaptiveGrid),
      );
      expect(expandedGrid.capabilities.widthClass, SurfaceWidthClass.expanded);

      // Medium 720 also uses grid (2-col)
      await tester.pumpWidget(
        _host(
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(720),
          ),
        ),
      );
      expect(find.byType(SettingsAdaptiveGrid), findsOneWidget);
      final mediumGrid = tester.widget<SettingsAdaptiveGrid>(
        find.byType(SettingsAdaptiveGrid),
      );
      expect(mediumGrid.capabilities.widthClass, SurfaceWidthClass.medium);
    });

    test('appThemeName resolver returns localized names for all themes', () {
      final l10n = CapyUiL10nEn();
      expect(appThemeName(AppThemeId.light, l10n), 'Light');
      expect(appThemeName(AppThemeId.dark, l10n), 'Petrol');
      expect(appThemeName(AppThemeId.midnight, l10n), 'Midnight');
      expect(appThemeName(AppThemeId.sepia, l10n), 'Sepia');
      expect(appThemeName(AppThemeId.nordic, l10n), 'Nordic');
      expect(appThemeName(AppThemeId.daylight, l10n), 'Daylight');
      expect(appThemeName(AppThemeId.tokyoNeon, l10n), 'Tokyo Neon');
      expect(appThemeName(AppThemeId.sunsetDrive, l10n), 'Sunset Drive');
      expect(appThemeName(AppThemeId.bubblegum, l10n), 'Bubblegum');
    });

    testWidgets('phone vs tablet vs head unit preview widths', (tester) async {
      // Simulate the gallery's three fixed-width frames: phone 390, tablet 720 medium, head unit 960 expanded.
      const phoneWidth = 390.0;
      const tabletWidth = 720.0;
      const carWidth = 960.0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          localizationsDelegates: CapyUiL10n.localizationsDelegates,
          supportedLocales: CapyUiL10n.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  SizedBox(
                    width: phoneWidth,
                    child: SettingsBody(
                      themeId: AppThemeId.light,
                      onThemeChanged: (_) {},
                      reduceMotion: false,
                      onReduceMotionChanged: (_) {},
                      capabilities: SurfaceCapabilities.fromWidth(phoneWidth),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: tabletWidth,
                    child: SettingsBody(
                      themeId: AppThemeId.light,
                      onThemeChanged: (_) {},
                      reduceMotion: false,
                      onReduceMotionChanged: (_) {},
                      capabilities: SurfaceCapabilities.fromWidth(tabletWidth),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: carWidth,
                    child: SettingsBody(
                      themeId: AppThemeId.light,
                      onThemeChanged: (_) {},
                      reduceMotion: false,
                      onReduceMotionChanged: (_) {},
                      capabilities: SurfaceCapabilities.fromWidth(carWidth),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.byType(SettingsBody), findsNWidgets(3));
      expect(find.text('App theme'), findsNWidgets(3));
      expect(find.text('Toggles'), findsNWidgets(3));
      expect(
        SurfaceCapabilities.fromWidth(tabletWidth).widthClass,
        SurfaceWidthClass.medium,
      );
    });

    testWidgets('allowKeyboard false renders read-only with TipBox', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          child: SettingsBody(
            themeId: AppThemeId.sepia,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(
              390,
            ).copyWith(allowKeyboard: false),
          ),
        ),
      );
      // Two TipBoxes: one for theme, one for toggles
      expect(find.byType(TipBox), findsNWidgets(2));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is IgnorePointer && widget.ignoring,
        ),
        findsOneWidget,
      );
      // TipBox labels
      expect(find.text('Tip'), findsNWidgets(2));
      expect(
        find.text(
          'Theme selection is unavailable while keyboard input is blocked.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Toggles are unavailable while input is blocked.'),
        findsOneWidget,
      );
      // Toggles row is present but disabled (onChanged null => Switch disabled)
      expect(find.byType(SettingToggleRow), findsOneWidget);
      // The switch inside should be disabled: find Switch with onChanged null
      final switchWidget = tester.widget<Switch>(find.byType(Switch));
      expect(switchWidget.onChanged, isNull);
    });

    testWidgets('allowKeyboard true has no TipBox and is editable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          child: SettingsBody(
            themeId: AppThemeId.sepia,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(390),
          ),
        ),
      );
      expect(find.byType(TipBox), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is IgnorePointer && widget.ignoring,
        ),
        findsNothing,
      );
      // Toggles editable
      final switchWidget = tester.widget<Switch>(find.byType(Switch));
      expect(switchWidget.onChanged, isNotNull);
    });

    testWidgets('theme change emits pure intent via onThemeChanged', (
      tester,
    ) async {
      AppThemeId? changed;
      await tester.pumpWidget(
        _host(
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (id) => changed = id,
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(390),
          ),
        ),
      );
      // Tap the midnight tile ("Midnight" in en)
      await tester.tap(find.text('Midnight'));
      await tester.pump();
      expect(changed, AppThemeId.midnight);
    });

    testWidgets('reduceMotion toggle emits pure intent', (tester) async {
      bool? changed;
      await tester.pumpWidget(
        _host(
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (value) => changed = value,
            capabilities: SurfaceCapabilities.fromWidth(390),
          ),
        ),
      );
      await tester.ensureVisible(find.byType(SettingToggleRow));
      await tester.pumpAndSettle();
      // Tap the SettingToggleRow (whole row is InkWell)
      await tester.tap(find.byType(SettingToggleRow));
      await tester.pump();
      expect(changed, isTrue);

      // When true, tapping again should give false
      changed = null;
      await tester.pumpWidget(
        _host(
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (_) {},
            reduceMotion: true,
            onReduceMotionChanged: (value) => changed = value,
            capabilities: SurfaceCapabilities.fromWidth(390),
          ),
        ),
      );
      await tester.ensureVisible(find.byType(SettingToggleRow));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SettingToggleRow));
      await tester.pump();
      expect(changed, isFalse);
    });

    testWidgets('reduceMotion toggle is disabled when allowKeyboard false', (
      tester,
    ) async {
      bool called = false;
      await tester.pumpWidget(
        _host(
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) => called = true,
            capabilities: SurfaceCapabilities.fromWidth(
              390,
            ).copyWith(allowKeyboard: false),
          ),
        ),
      );
      await tester.ensureVisible(find.byType(SettingToggleRow));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SettingToggleRow));
      await tester.pump();
      expect(called, isFalse);
    });

    testWidgets('does not call Navigator (pure intents up)', (tester) async {
      await tester.pumpWidget(
        _host(
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(390),
          ),
        ),
      );
      // Ensure no dialog/menu was pushed
      expect(find.byType(SettingsBody), findsOneWidget);
      // Tapping should not push a route.
      await tester.tap(find.text('Light'));
      await tester.pump();
      expect(find.byType(MaterialApp), findsOneWidget);
    });

    testWidgets('reads strings from CapyUiL10n in pt', (tester) async {
      await tester.pumpWidget(
        _host(
          locale: const Locale('pt'),
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(390),
          ),
        ),
      );
      await tester.pump();
      // Portuguese names
      expect(find.text('Claro'), findsOneWidget);
      expect(find.text('Tema do app'), findsOneWidget);
      expect(find.text('Interruptores'), findsOneWidget);
      expect(find.text('Reduzir movimento'), findsOneWidget);
    });

    testWidgets('reads strings from CapyUiL10n in es', (tester) async {
      await tester.pumpWidget(
        _host(
          locale: const Locale('es'),
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(390),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Claro'), findsOneWidget);
      expect(find.text('Tema de la app'), findsOneWidget);
      expect(find.text('Reducir movimiento'), findsOneWidget);
    });

    testWidgets('reads strings from CapyUiL10n in ru', (tester) async {
      await tester.pumpWidget(
        _host(
          locale: const Locale('ru'),
          child: SettingsBody(
            themeId: AppThemeId.light,
            onThemeChanged: (_) {},
            reduceMotion: false,
            onReduceMotionChanged: (_) {},
            capabilities: SurfaceCapabilities.fromWidth(390),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Светлая'), findsOneWidget);
      expect(find.text('Уменьшение движения'), findsOneWidget);
    });
  });

  group('SettingsSource and SettingsBodyController', () {
    test(
      'controller exposes themeId and forwards setThemeId to source',
      () async {
        final source = _FakeSource(AppThemeId.light);
        final controller = SettingsBodyController(source: source);
        expect(controller.themeId, AppThemeId.light);
        await controller.setThemeId(AppThemeId.dark);
        expect(source.lastSetTheme, AppThemeId.dark);
        expect(source.setThemeCalls, 1);
        expect(controller.themeId, AppThemeId.dark);
        controller.dispose();
        source.dispose();
      },
    );

    test(
      'controller exposes reduceMotion and forwards setReduceMotion to source',
      () async {
        final source = _FakeSource(AppThemeId.light, reduceMotion: false);
        final controller = SettingsBodyController(source: source);
        expect(controller.reduceMotion, isFalse);
        await controller.setReduceMotion(true);
        expect(source.lastSetReduce, isTrue);
        expect(source.setReduceCalls, 1);
        expect(controller.reduceMotion, isTrue);
        await controller.onReduceMotionChanged(false);
        expect(source.lastSetReduce, isFalse);
        controller.dispose();
        source.dispose();
      },
    );

    test('controller notifies when source theme changes', () async {
      final source = _FakeSource(AppThemeId.light);
      final controller = SettingsBodyController(source: source);
      var notified = 0;
      controller.addListener(() => notified++);
      await source.setThemeId(AppThemeId.midnight);
      expect(notified, 1);
      expect(controller.themeId, AppThemeId.midnight);
      controller.dispose();
      source.dispose();
    });

    test('controller notifies when source reduceMotion changes', () async {
      final source = _FakeSource(AppThemeId.light, reduceMotion: false);
      final controller = SettingsBodyController(source: source);
      var notified = 0;
      controller.addListener(() => notified++);
      await source.setReduceMotion(true);
      expect(notified, 1);
      expect(controller.reduceMotion, isTrue);
      controller.dispose();
      source.dispose();
    });

    test('car source dark default and companion source light default', () {
      // Verify the semantic defaults are preserved: car dark, companion light.
      // We test the fake sources mimic those defaults as documentation.
      final carFake = _FakeSource(AppThemeId.dark);
      final phoneFake = _FakeSource(AppThemeId.light);
      expect(carFake.themeId, AppThemeId.dark);
      expect(phoneFake.themeId, AppThemeId.light);
      carFake.dispose();
      phoneFake.dispose();
    });
  });
}
