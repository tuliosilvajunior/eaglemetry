import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/carplay_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/l10n/app_localizations_en.dart';
import 'package:capy_energy/screens_v2/carplay_home_v2_screen.dart';
import 'package:capy_energy/screens_v2/carplay_v2_screen.dart';
import 'package:capy_energy/core/energy_monitor_controller.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_ui/capy_ui.dart';

/// Regression cover for what this tab promises: the video surface rests at
/// 3/4 of the stage, it is the card that can be dragged to fill the screen —
/// the gesture the "Now" destination used to own — and the card beside it
/// carries the session ring rather than chrome of its own. The
/// stage mechanism itself has its own suite in `card_stage_test.dart`; this
/// only has to prove which slot was wired as
/// [ExpandableCardStage.expandableIndex] and at what width, not re-test the
/// drag math.
void main() {
  Future<CardStageController> pumpCarplay(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: _Harness(key: key)),
      ),
    );
    await tester.pumpAndSettle();
    return key.currentState!.stage;
  }

  testWidgets('the CarPlay surface rests at three quarters of the stage', (
    tester,
  ) async {
    await pumpCarplay(tester);

    final surface = tester.getSize(find.byType(CarplayV2Screen)).width;
    final context = tester
        .getSize(
          find.ancestor(
            of: find.text(AppLocalizationsEn().sessionDetailsTitle),
            matching: find.byType(AppCard),
          ),
        )
        .width;

    // Three units against one, whatever the gutter between them costs.
    expect(surface, closeTo(context * 3, 0.5));
  });

  Future<void> dragUp(WidgetTester tester, Offset from) async {
    final gesture = await tester.startGesture(from);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('dragging the grip takes the CarPlay card fullscreen', (
    tester,
  ) async {
    final stage = await pumpCarplay(tester);
    expect(stage.isFullscreen, isFalse);

    await dragUp(tester, tester.getCenter(find.byType(CardStageDragHandle)));

    expect(stage.isFullscreen, isTrue);
  });

  testWidgets(
    'dragging the surface itself belongs to the phone, not the card',
    (tester) async {
      // The regression this exists for: the stage used to claim every drag on
      // the card. The surface forwards its drags to CarPlay, where the same
      // gesture scrolls a list, so a drag over the video must not also resize
      // the card behind it.
      final stage = await pumpCarplay(tester);
      expect(stage.isFullscreen, isFalse);

      await dragUp(tester, tester.getCenter(find.byType(CarplayV2Screen)));

      expect(stage.isFullscreen, isFalse);
    },
  );

  testWidgets('going fullscreen keeps the very same surface alive', (
    tester,
  ) async {
    final stage = await pumpCarplay(tester);
    final api = tester.state<_HarnessState>(find.byType(_Harness))._api;
    final before = tester.state(find.byType(CarplayV2Screen));
    expect(api.activateCount, 1);

    stage.expand();
    await tester.pumpAndSettle();

    // The regression this exists for: `CardSize` flipping to `fullscreen` used
    // to re-key the slot, disposing the surface and recreating it. On a head
    // unit that dispose is a `deactivate()` — detach, texture released,
    // service unbound — and it lands *after* the replacement's `activate()`,
    // so the video died at the end of every expand gesture and never came
    // back. Same `State`, one activation, no deactivation.
    expect(tester.state(find.byType(CarplayV2Screen)), same(before));
    expect(api.activateCount, 1);
    expect(api.deactivateCount, 0);
  });

  testWidgets('dragging the context card does not expand anything', (
    tester,
  ) async {
    final stage = await pumpCarplay(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text(AppLocalizationsEn().sessionDetailsTitle)),
    );
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(stage.isFullscreen, isFalse);
    expect(stage.expansion, 0);
  });
}

class _Harness extends StatefulWidget {
  const _Harness({super.key});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> with TickerProviderStateMixin {
  late final CardStageController stage = CardStageController(vsync: this);

  /// Kept off the platform channels, and off any timer: this suite is about
  /// the stage, and the ring beside the surface only has to build.
  final energy = EnergyMonitorController(
    telemetryApi: TelemetryApi(source: MockTelemetrySource()),
    livePollInterval: const Duration(hours: 1),
    storedReloadInterval: const Duration(hours: 1),
  );
  final _api = _SilentCarplayApi();

  @override
  void dispose() {
    energy.dispose();
    stage.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CarplayHomeV2Screen(
      title: 'CarPlay',
      isActive: true,
      stage: stage,
      energyController: energy,
      carplayApi: _api,
    );
  }
}

/// Keeps the surface off the platform channels. What it reports does not
/// matter here — the empty status renders the card's placeholder copy, and
/// this suite is about the slot's geometry and its gesture, not the video.
class _SilentCarplayApi extends CarplayApi {
  int refreshCount = 0;
  int activateCount = 0;
  int deactivateCount = 0;

  Completer<CarplayStatus>? _held;

  /// Makes the next [refresh] hang until [release], so a test can act while a
  /// call is genuinely in flight.
  void hold() => _held = Completer<CarplayStatus>();

  void release() => _held?.complete(CarplayStatus.empty);

  @override
  Future<CarplayStatus> getStatus() async => CarplayStatus.empty;

  @override
  Future<CarplayStatus> activate({int? width, int? height}) async {
    activateCount++;
    return CarplayStatus.empty;
  }

  @override
  Future<CarplayStatus> deactivate() async {
    deactivateCount++;
    return CarplayStatus.empty;
  }

  @override
  Future<CarplayStatus> refresh() {
    refreshCount++;
    return _held?.future ?? Future.value(CarplayStatus.empty);
  }

  @override
  Stream<CarplayStatus> statusStream() => const Stream.empty();
}
