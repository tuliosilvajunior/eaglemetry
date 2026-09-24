import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/app_experience_controller.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/experience_welcome_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _buildTestableApp({required VoidCallback onMounted}) {
  return MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: const [Locale('pt')],
    home: _TestHome(onMounted: onMounted),
  );
}

class _TestHome extends StatefulWidget {
  const _TestHome({required this.onMounted});

  final VoidCallback onMounted;

  @override
  State<_TestHome> createState() => _TestHomeState();
}

class _TestHomeState extends State<_TestHome> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onMounted());
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Text('Home Screen'));
  }
}

void main() {
  final controller = AppExperienceController.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await controller.reset();
  });

  tearDown(() async {
    await controller.reset();
  });

  testWidgets('shows welcome dialog when welcomeSeen is false', (tester) async {
    await tester.pumpWidget(
      _buildTestableApp(
        onMounted: () {
          final context = tester.element(find.text('Home Screen'));
          showExperienceWelcomeDialog(context);
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('experience-welcome-dialog')), findsOneWidget);
    expect(find.text('Experiência Versão 1.0'), findsOneWidget);
  });

  testWidgets('tapping explore dismisses dialog and marks welcome as seen', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildTestableApp(
        onMounted: () {
          final context = tester.element(find.text('Home Screen'));
          showExperienceWelcomeDialog(context);
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Explorar Nova Experiência'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('experience-welcome-dialog')), findsNothing);
    expect(controller.welcomeSeen, isTrue);
    expect(controller.newUiEnabled, isTrue);
  });

  testWidgets('tapping legacy mode switches to legacy and marks as seen', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildTestableApp(
        onMounted: () {
          final context = tester.element(find.text('Home Screen'));
          showExperienceWelcomeDialog(context);
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Usar Modo Antigo'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('experience-welcome-dialog')), findsNothing);
    expect(controller.welcomeSeen, isTrue);
    expect(controller.newUiEnabled, isFalse);
  });

  testWidgets('does not show dialog if welcomeSeen is true', (tester) async {
    await controller.setWelcomeSeen(true);

    await tester.pumpWidget(
      _buildTestableApp(
        onMounted: () {
          final context = tester.element(find.text('Home Screen'));
          showExperienceWelcomeDialog(context);
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('experience-welcome-dialog')), findsNothing);
  });
}
