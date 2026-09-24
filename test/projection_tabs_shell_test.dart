import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/android_auto_api.dart';
import 'package:capy_energy/core/app_experience_controller.dart';
import 'package:capy_energy/core/carplay_api.dart';
import 'package:capy_energy/core/projection_presence_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/app_shell_v2.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The shell end of the projection rule: one beta switch, two OEM
/// stacks, and only the tab for the phone that is actually there.
///
/// `projection_presence_test.dart` pins the rule itself. This file pins that
/// the shell feeds it the real inputs and reacts to a live change.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppExperienceController.instance.reset();
  });

  tearDown(() async {
    await AppExperienceController.instance.reset();
  });

  Future<_Fakes> pumpShell(
    WidgetTester tester, {
    required ProjectionPresence presence,
  }) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await AppExperienceController.instance.setProjectionEnabled(true);

    final fakes = _Fakes(presence);
    addTearDown(fakes.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppShellV2(
          carplayApi: fakes.carplay,
          androidAutoApi: fakes.androidAuto,
          projectionPresenceApi: fakes.presence,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return fakes;
  }

  testWidgets('a connected iPhone shows CarPlay alone', (tester) async {
    await pumpShell(
      tester,
      presence: const ProjectionPresence(
        carplay: PresenceState.connected,
        androidAuto: PresenceState.disconnected,
        carplayAvailable: true,
        androidAutoAvailable: true,
        carplayEdgeAt: 10,
        androidAutoEdgeAt: null,
      ),
    );

    expect(find.text('CarPlay'), findsOneWidget);
    expect(find.text('Android Auto'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a connected Android phone shows Android Auto alone', (
    tester,
  ) async {
    await pumpShell(
      tester,
      presence: const ProjectionPresence(
        carplay: PresenceState.disconnected,
        androidAuto: PresenceState.connected,
        carplayAvailable: true,
        androidAutoAvailable: true,
        carplayEdgeAt: null,
        androidAutoEdgeAt: 10,
      ),
    );

    expect(find.text('Android Auto'), findsOneWidget);
    expect(find.text('CarPlay'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no phone shows neither tab, although both services bind', (
    tester,
  ) async {
    // The state the old `bound` rule got wrong: both OEM apps are installed on
    // every one of these head units, so both bind and neither has a phone.
    await pumpShell(
      tester,
      presence: const ProjectionPresence(
        carplay: PresenceState.disconnected,
        androidAuto: PresenceState.disconnected,
        carplayAvailable: true,
        androidAutoAvailable: true,
        carplayEdgeAt: null,
        androidAutoEdgeAt: null,
      ),
    );

    expect(find.text('CarPlay'), findsNothing);
    expect(find.text('Android Auto'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unknown presence falls back to the bound services', (
    tester,
  ) async {
    // A probe that failed must not hide a card that would have worked.
    await pumpShell(tester, presence: ProjectionPresence.unknown);

    expect(find.text('CarPlay'), findsOneWidget);
    expect(find.text('Android Auto'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('swapping the phone swaps the tab, with no restart', (
    tester,
  ) async {
    final fakes = await pumpShell(
      tester,
      presence: const ProjectionPresence(
        carplay: PresenceState.connected,
        androidAuto: PresenceState.disconnected,
        carplayAvailable: true,
        androidAutoAvailable: true,
        carplayEdgeAt: 10,
        androidAutoEdgeAt: null,
      ),
    );
    expect(find.text('CarPlay'), findsOneWidget);

    fakes.presence.emit(
      const ProjectionPresence(
        carplay: PresenceState.disconnected,
        androidAuto: PresenceState.connected,
        carplayAvailable: true,
        androidAutoAvailable: true,
        carplayEdgeAt: 10,
        androidAutoEdgeAt: 20,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Android Auto'), findsOneWidget);
    expect(find.text('CarPlay'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the beta switch gates both stacks at once', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Left off: a connected phone on each stack must still reach nothing,
    // because off means the services are never started at all.
    final fakes = _Fakes(
      const ProjectionPresence(
        carplay: PresenceState.connected,
        androidAuto: PresenceState.connected,
        carplayAvailable: true,
        androidAutoAvailable: true,
        carplayEdgeAt: 10,
        androidAutoEdgeAt: 20,
      ),
    );
    addTearDown(fakes.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppShellV2(
          carplayApi: fakes.carplay,
          androidAutoApi: fakes.androidAuto,
          projectionPresenceApi: fakes.presence,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('CarPlay'), findsNothing);
    expect(find.text('Android Auto'), findsNothing);
    expect(fakes.presence.reads, 0);
    expect(fakes.androidAuto.reads, 0);
    expect(fakes.carplay.reads, 0);

    await AppExperienceController.instance.setProjectionEnabled(true);
    await tester.pump();
    await tester.pump();

    // Both connected, Android Auto's edge is the newer one.
    expect(find.text('Android Auto'), findsOneWidget);
    expect(find.text('CarPlay'), findsNothing);
    expect(fakes.presence.reads, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}

class _Fakes {
  _Fakes(ProjectionPresence presence)
    : presence = _FakePresenceApi(presence),
      carplay = _FakeCarplayApi(),
      androidAuto = _FakeAndroidAutoApi();

  final _FakePresenceApi presence;
  final _FakeCarplayApi carplay;
  final _FakeAndroidAutoApi androidAuto;

  void dispose() {
    presence.dispose();
    carplay.dispose();
    androidAuto.dispose();
  }
}

class _FakePresenceApi extends ProjectionPresenceApi {
  _FakePresenceApi(this._presence);

  ProjectionPresence _presence;
  final _controller = StreamController<ProjectionPresence>.broadcast();

  /// Proves the shell asked at all, which is what the beta switch gates.
  int reads = 0;

  void emit(ProjectionPresence next) {
    _presence = next;
    _controller.add(next);
  }

  @override
  Future<ProjectionPresence> getPresence() async {
    reads++;
    return _presence;
  }

  @override
  Future<ProjectionPresence> refresh() async {
    reads++;
    return _presence;
  }

  @override
  Stream<ProjectionPresence> presenceStream() => _controller.stream;

  void dispose() => _controller.close();
}

/// Bound and available, which is the true state on every one of these head
/// units. The tab must come from presence, not from this.
class _FakeCarplayApi extends CarplayApi {
  final _status = CarplayStatus.empty.copyWith(available: true, bound: true);
  final _controller = StreamController<CarplayStatus>.broadcast();

  int reads = 0;

  @override
  Future<CarplayStatus> getStatus() async {
    reads++;
    return _status;
  }

  @override
  Future<CarplayStatus> activate({int? width, int? height}) async => _status;

  @override
  Future<CarplayStatus> deactivate() async => _status;

  @override
  Future<CarplayStatus> refresh() async => _status;

  @override
  Stream<CarplayStatus> statusStream() => _controller.stream;

  void dispose() => _controller.close();
}

class _FakeAndroidAutoApi extends AndroidAutoApi {
  final _status = AndroidAutoStatus.empty.copyWith(
    available: true,
    bound: true,
  );
  final _controller = StreamController<AndroidAutoStatus>.broadcast();

  int reads = 0;

  @override
  Future<AndroidAutoStatus> getStatus() async {
    reads++;
    return _status;
  }

  @override
  Future<AndroidAutoStatus> activate({int? width, int? height}) async =>
      _status;

  @override
  Future<AndroidAutoStatus> deactivate() async => _status;

  @override
  Future<AndroidAutoStatus> refresh() async => _status;

  @override
  Stream<AndroidAutoStatus> statusStream() => _controller.stream;

  void dispose() => _controller.close();
}
