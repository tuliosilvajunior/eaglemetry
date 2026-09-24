import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/android_auto_api.dart';
import 'package:capy_energy/core/app_experience_controller.dart';
import 'package:capy_energy/core/app_navigation_controller.dart';
import 'package:capy_energy/core/carplay_api.dart';
import 'package:capy_energy/core/projection_presence_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/screens_v2/app_shell_v2.dart';
import 'package:capy_energy/screens_v2/carplay_home_v2_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The shell end of the projection auto-open.
///
/// `ProjectionAutoOpenSupervisor` brings the app forward when a phone arrives,
/// and names the tab in the launch intent. This file pins what the shell does
/// with that name, including the case the charging half never had: a tab that
/// does not exist until a reading lands.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppExperienceController.instance.reset();
    AppNavigationController.instance.clearPending();
  });

  tearDown(() async {
    await AppExperienceController.instance.reset();
    AppNavigationController.instance.clearPending();
  });

  Future<_Fakes> pumpShell(
    WidgetTester tester, {
    required ProjectionPresence presence,
    bool holdStatus = false,
  }) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await AppExperienceController.instance.setProjectionEnabled(true);

    final fakes = _Fakes(presence, holdStatus: holdStatus);
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

  const iPhone = ProjectionPresence(
    carplay: PresenceState.connected,
    androidAuto: PresenceState.disconnected,
    carplayAvailable: true,
    androidAutoAvailable: true,
    carplayEdgeAt: 10,
    androidAutoEdgeAt: null,
  );

  const noPhone = ProjectionPresence(
    carplay: PresenceState.disconnected,
    androidAuto: PresenceState.disconnected,
    carplayAvailable: true,
    androidAutoAvailable: true,
    carplayEdgeAt: null,
    androidAutoEdgeAt: null,
  );

  testWidgets('a launch for CarPlay opens the CarPlay tab', (tester) async {
    // The cold-start route: the native side kept the destination, and the app
    // reads it as it starts.
    AppNavigationController.instance.navigateTo(
      AppNavigationController.carplay,
    );

    await pumpShell(tester, presence: iPhone);
    await tester.pumpAndSettle();

    expect(find.byType(CarplayHomeV2Screen), findsOneWidget);
    expect(AppNavigationController.instance.pendingDestination, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a launch that arrives before the reading waits for it', (
    tester,
  ) async {
    // The real cold start. Presence is unknown for a moment, so the phone's
    // tab does not exist yet and the request cannot be answered. It must not
    // be thrown away for that.
    AppNavigationController.instance.navigateTo(
      AppNavigationController.carplay,
    );

    final fakes = await pumpShell(
      tester,
      presence: ProjectionPresence.unknown,
      holdStatus: true,
    );
    expect(
      AppNavigationController.instance.pendingDestination,
      AppNavigationController.carplay,
      reason: 'an unknown presence is not an answer',
    );

    fakes.presence.emit(iPhone);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(CarplayHomeV2Screen), findsOneWidget);
    expect(AppNavigationController.instance.pendingDestination, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a launch for a phone that is not there is dropped', (
    tester,
  ) async {
    // Presence has answered, and the answer is no phone. The request describes
    // one launch, so it must not sit and wait to fire at some later
    // connection.
    AppNavigationController.instance.navigateTo(
      AppNavigationController.carplay,
    );

    await pumpShell(tester, presence: noPhone);
    await tester.pumpAndSettle();

    expect(find.byType(CarplayHomeV2Screen), findsNothing);
    expect(AppNavigationController.instance.pendingDestination, isNull);
    expect(tester.takeException(), isNull);
  });
}

class _Fakes {
  _Fakes(ProjectionPresence presence, {bool holdStatus = false})
    : presence = _FakePresenceApi(presence),
      carplay = _FakeCarplayApi(holdStatus),
      androidAuto = _FakeAndroidAutoApi(holdStatus);

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
  _FakeCarplayApi([this.held = false]);

  /// A read that has not landed yet, which is the state of a cold start. It
  /// leaves `bound` false, so the fallback cannot stand in for presence.
  final bool held;

  final _status = CarplayStatus.empty.copyWith(available: true, bound: true);
  final _controller = StreamController<CarplayStatus>.broadcast();

  int reads = 0;

  @override
  Future<CarplayStatus> getStatus() async {
    reads++;
    if (held) return CarplayStatus.empty;
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
  _FakeAndroidAutoApi([this.held = false]);

  final bool held;

  final _status = AndroidAutoStatus.empty.copyWith(
    available: true,
    bound: true,
  );
  final _controller = StreamController<AndroidAutoStatus>.broadcast();

  int reads = 0;

  @override
  Future<AndroidAutoStatus> getStatus() async {
    reads++;
    if (held) return AndroidAutoStatus.empty;
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
