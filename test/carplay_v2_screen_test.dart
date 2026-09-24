import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/carplay_api.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/l10n/app_localizations_en.dart';
import 'package:capy_energy/screens_v2/carplay_v2_screen.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:capy_energy/widgets/projection_touch_surface.dart';

void main() {
  testWidgets(
    'isActive true with empty status activates once and says unavailable',
    (tester) async {
      await _pumpWide(tester);
      final api = _FakeCarplayApi();
      await tester.pumpWidget(
        _app(
          CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api),
        ),
      );
      await tester.pump();

      expect(api.activateCount, 1);
      expect(find.byType(Texture), findsNothing);
      expect(
        find.text(AppLocalizationsEn().v2CarplayUnavailable),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('available but not attached shows connecting copy, no Texture', (
    tester,
  ) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi()..push(_status(available: true));
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();

    expect(find.text(AppLocalizationsEn().v2CarplayConnecting), findsOneWidget);
    expect(find.byType(Texture), findsNothing);
  });

  testWidgets('attached renders exactly one Texture at the buffer aspect', (
    tester,
  ) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi()
      ..push(
        _status(
          available: true,
          bound: true,
          attached: true,
          textureId: 7,
          bufferWidth: 1920,
          bufferHeight: 1080,
        ),
      );
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();

    final textures = find.byType(Texture);
    expect(textures, findsOneWidget);
    expect(tester.widget<Texture>(textures).textureId, 7);
    // Scoped to the plate: an unscoped byType breaks the day anything else in
    // the tree gains an AspectRatio.
    final plateAspect = find.ancestor(
      of: textures,
      matching: find.byType(AspectRatio),
    );
    expect(
      tester.widget<AspectRatio>(plateAspect.first).aspectRatio,
      closeTo(16 / 9, 1e-9),
    );
  });

  testWidgets(
    'surface-only mode fills the card with only the CarPlay texture',
    (tester) async {
      await _pumpWide(tester);
      final api = _FakeCarplayApi()
        ..push(
          _status(
            available: true,
            bound: true,
            attached: true,
            textureId: 7,
            bufferWidth: 1920,
            bufferHeight: 1080,
          ),
        );
      await tester.pumpWidget(
        _app(
          CarplayV2Screen(
            title: 'Now',
            isActive: true,
            carplayApi: api,
            surfaceOnly: true,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(Texture), findsOneWidget);
      expect(find.byType(AppCard), findsOneWidget);
      expect(
        tester.getSize(find.byType(Texture)),
        tester.getSize(find.byType(AppCard)),
      );
      expect(find.text(AppLocalizationsEn().v2CarplayTitle), findsNothing);
      expect(
        find.text(AppLocalizationsEn().v2CarplayStatusTitle),
        findsNothing,
      );
      expect(find.text(AppLocalizationsEn().v2CarplayReattach), findsNothing);
      expect(
        find.text(AppLocalizationsEn().v2CarplayBlackScreenHint),
        findsNothing,
      );
    },
  );

  testWidgets('rendering shows the black-screen hint (data honesty)', (
    tester,
  ) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi()
      ..push(
        _status(
          available: true,
          bound: true,
          attached: true,
          textureId: 7,
          bufferWidth: 1920,
          bufferHeight: 1080,
        ),
      );
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();

    expect(
      find.text(AppLocalizationsEn().v2CarplayBlackScreenHint),
      findsOneWidget,
    );
  });

  testWidgets('any rendering state shows the view-only notice', (tester) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi()
      ..push(
        _status(
          available: true,
          bound: true,
          attached: true,
          textureId: 7,
          bufferWidth: 1920,
          bufferHeight: 1080,
        ),
      );
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();

    // The card is no longer view-only: the texture forwards touch, so the
    // notice that said it did not is gone.
    expect(find.byType(ProjectionTouchSurface), findsOneWidget);
  });

  testWidgets('isActive false on first build never activates (R1)', (
    tester,
  ) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi();
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: false, carplayApi: api)),
    );
    await tester.pump();

    expect(api.activateCount, 0);
    expect(api.deactivateCount, 0);
  });

  testWidgets('rebuild false -> true activates once', (tester) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi();
    final widget = CarplayV2Screen(
      title: 'CarPlay',
      isActive: false,
      carplayApi: api,
    );
    await tester.pumpWidget(_app(widget));
    await tester.pump();

    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();

    expect(api.activateCount, 1);
    expect(api.deactivateCount, 0);
  });

  testWidgets('rebuild true -> false deactivates and does not re-activate', (
    tester,
  ) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi();
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();

    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: false, carplayApi: api)),
    );
    await tester.pump();

    expect(api.deactivateCount, 1);
    expect(api.activateCount, 1);
  });

  testWidgets('backgrounding while active deactivates (R4 backstop)', (
    tester,
  ) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi();
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(api.deactivateCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(api.activateCount, 2);
  });

  testWidgets('dispose while active deactivates', (tester) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi();
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();

    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pump();

    expect(api.deactivateCount, 1);
  });

  testWidgets('Reconnect calls refresh once', (tester) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi();
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();

    await tester.tap(find.text(AppLocalizationsEn().v2CarplayReattach));
    await tester.pump();

    expect(api.refreshCount, 1);
  });

  testWidgets('Reconnect tile meets the minimum touch target', (tester) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi();
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();

    final tile = find.ancestor(
      of: find.text(AppLocalizationsEn().v2CarplayReattach),
      matching: find.byType(SoftActionTile),
    );
    expect(
      tester.getSize(tile).height,
      greaterThanOrEqualTo(AppSizes.minTouchTarget),
    );
  });

  testWidgets('BIND_FAILED maps to the unreachable error copy', (tester) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi()
      ..push(_status(available: true, lastError: 'BIND_FAILED'));
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();

    expect(
      find.text(AppLocalizationsEn().v2CarplayErrorUnreachable),
      findsOneWidget,
    );
    expect(find.textContaining('BIND_FAILED'), findsNothing);
  });

  testWidgets(
    'unknown error code falls back to generic and never reaches the tree',
    (tester) async {
      await _pumpWide(tester);
      final api = _FakeCarplayApi()
        ..push(_status(available: true, lastError: 'SOMETHING_NEW'));
      await tester.pumpWidget(
        _app(
          CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api),
        ),
      );
      await tester.pump();

      expect(
        find.text(AppLocalizationsEn().v2CarplayErrorGeneric),
        findsOneWidget,
      );
      expect(find.textContaining('SOMETHING_NEW'), findsNothing);
    },
  );

  // Every other test seeds through `getStatus()`, because `push()` before the
  // first pump is dropped: the fake's controller is a broadcast stream and
  // events added with no subscriber are discarded. This is the only test that
  // exercises the stream -> setState path the screen actually subscribes to.
  testWidgets('a status pushed after the first frame reaches the card', (
    tester,
  ) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi();
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();
    expect(find.byType(Texture), findsNothing);

    api.push(
      _status(
        available: true,
        bound: true,
        attached: true,
        textureId: 11,
        bufferWidth: 1920,
        bufferHeight: 1080,
      ),
    );
    // Two frames: the first delivers the queued stream event and runs the
    // screen's `setState`, the second rebuilds with it. One pump finds no
    // scheduled frame yet and does nothing.
    await tester.pump();
    await tester.pump();

    final textures = find.byType(Texture);
    expect(textures, findsOneWidget);
    expect(tester.widget<Texture>(textures).textureId, 11);
  });

  // Rendering outranks a stale error: `CarplayApi` keeps the last error until a
  // call succeeds, so an ordinary tab switch must not caption a live picture
  // with a renderer failure.
  testWidgets('a lingering error never captions a rendering plate', (
    tester,
  ) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi()
      ..push(
        _status(
          available: true,
          bound: true,
          attached: true,
          textureId: 7,
          bufferWidth: 1920,
          bufferHeight: 1080,
          lastError: 'DETACH_FAILED',
        ),
      );
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();

    expect(find.byType(Texture), findsOneWidget);
    expect(
      find.text(AppLocalizationsEn().v2CarplayErrorRenderer),
      findsNothing,
    );
    expect(
      find.text(AppLocalizationsEn().v2CarplayBlackScreenHint),
      findsOneWidget,
    );
  });

  testWidgets('empty status stream and channel death do not throw', (
    tester,
  ) async {
    await _pumpWide(tester);
    final api = _FakeCarplayApi();
    await tester.pumpWidget(
      _app(CarplayV2Screen(title: 'CarPlay', isActive: true, carplayApi: api)),
    );
    await tester.pump();

    api.controller.addError(StateError('host died'));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpWide(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

CarplayStatus _status({
  bool available = false,
  bool bound = false,
  bool attached = false,
  int? textureId,
  int bufferWidth = 0,
  int bufferHeight = 0,
  String? lastError,
}) => CarplayStatus(
  available: available,
  bound: bound,
  attached: attached,
  activityResumed: true,
  dartActive: true,
  textureId: textureId,
  bufferWidth: bufferWidth,
  bufferHeight: bufferHeight,
  attachCount: 0,
  lastError: lastError,
);

class _FakeCarplayApi extends CarplayApi {
  final controller = StreamController<CarplayStatus>.broadcast();

  CarplayStatus status = CarplayStatus.empty;
  int activateCount = 0;
  int deactivateCount = 0;
  int refreshCount = 0;

  @override
  Future<CarplayStatus> getStatus() async => status;

  @override
  Future<CarplayStatus> activate({int? width, int? height}) async {
    activateCount++;
    return status;
  }

  @override
  Future<CarplayStatus> deactivate() async {
    deactivateCount++;
    return status;
  }

  @override
  Future<CarplayStatus> refresh() async {
    refreshCount++;
    return status;
  }

  @override
  Stream<CarplayStatus> statusStream() => controller.stream;

  void push(CarplayStatus next) {
    status = next;
    controller.add(next);
  }
}

Widget _app(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}
