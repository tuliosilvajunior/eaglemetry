import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/projection_touch_api.dart';
import 'package:capy_energy/widgets/projection_touch_surface.dart';

/// The Dart mirror of the native `ProjectionTouchPolicyTest` cases:
/// every send the widget produces must be shaped the way `decideMulti`
/// already expects — `POINTER_DOWN`/`POINTER_UP` with `actionIndex` naming
/// the changed finger inside the FULL live-pointer list.
void main() {
  group('ProjectionTouchSurface multitouch', () {
    testWidgets('android auto forwards a second finger with its index', (
      tester,
    ) async {
      final api = _FakeTouchApi();
      await _pumpSurface(tester, api, ProjectionStack.androidAuto);
      final center = tester.getCenter(find.byType(Texture));

      await tester.sendEventToBinding(
        TestPointer(1, PointerDeviceKind.touch).down(center),
      );
      await tester.pump();
      await tester.sendEventToBinding(
        TestPointer(2, PointerDeviceKind.touch).down(center),
      );
      await tester.pump();

      expect(api.sends.length, 2);
      final second = api.sends[1];
      expect(second.action, ProjectionTouchAction.pointerDown);
      expect(second.actionIndex, 1);
      expect(second.pointerIds, [1, 2]);
    });

    testWidgets(
      'a move carries every live finger, not just the one that moved',
      (tester) async {
        final api = _FakeTouchApi();
        await _pumpSurface(tester, api, ProjectionStack.androidAuto);
        final center = tester.getCenter(find.byType(Texture));

        final first = TestPointer(1, PointerDeviceKind.touch);
        final secondFinger = TestPointer(2, PointerDeviceKind.touch);
        await tester.sendEventToBinding(first.down(center));
        await tester.pump();
        await tester.sendEventToBinding(secondFinger.down(center));
        await tester.pump();
        await tester.sendEventToBinding(
          secondFinger.move(center + const Offset(10, 0)),
        );
        await tester.pump();

        final move = api.sends.last;
        expect(move.action, ProjectionTouchAction.move);
        expect(move.pointerIds, [1, 2]);
      },
    );

    testWidgets('lifting the second finger sends pointer up with its index', (
      tester,
    ) async {
      final api = _FakeTouchApi();
      await _pumpSurface(tester, api, ProjectionStack.androidAuto);
      final center = tester.getCenter(find.byType(Texture));

      final first = TestPointer(1, PointerDeviceKind.touch);
      final secondFinger = TestPointer(2, PointerDeviceKind.touch);
      await tester.sendEventToBinding(first.down(center));
      await tester.pump();
      await tester.sendEventToBinding(secondFinger.down(center));
      await tester.pump();
      await tester.sendEventToBinding(secondFinger.up());
      await tester.pump();

      final lift = api.sends.last;
      expect(lift.action, ProjectionTouchAction.pointerUp);
      expect(lift.actionIndex, 1);
      // The lifted finger is still named at its index: that is how the
      // native side knows which id to remove from its live list.
      expect(lift.pointerIds, [1, 2]);
    });

    testWidgets('lifting the last finger sends a plain up', (tester) async {
      final api = _FakeTouchApi();
      await _pumpSurface(tester, api, ProjectionStack.androidAuto);
      final center = tester.getCenter(find.byType(Texture));

      final first = TestPointer(1, PointerDeviceKind.touch);
      await tester.sendEventToBinding(first.down(center));
      await tester.pump();
      await tester.sendEventToBinding(first.up());
      await tester.pump();

      final lift = api.sends.last;
      expect(lift.action, ProjectionTouchAction.up);
      expect(lift.pointerIds, [1]);
    });

    testWidgets('carplay refuses a second finger and keeps the first', (
      tester,
    ) async {
      final api = _FakeTouchApi();
      await _pumpSurface(tester, api, ProjectionStack.carplay);
      final center = tester.getCenter(find.byType(Texture));

      await tester.sendEventToBinding(
        TestPointer(1, PointerDeviceKind.touch).down(center),
      );
      await tester.pump();
      await tester.sendEventToBinding(
        TestPointer(2, PointerDeviceKind.touch).down(center),
      );
      await tester.pump();

      // CarPlay is single-touch by protocol (one coordinate pair per frame),
      // so the second DOWN must stay a plain single-pointer DOWN — the native
      // `decideSingle` drops it as SECOND_POINTER without disturbing finger 1.
      for (final send in api.sends) {
        expect(send.action, ProjectionTouchAction.down);
        expect(send.pointerIds, hasLength(1));
      }
      expect(api.sends.length, 2);
    });
  });
}

Future<void> _pumpSurface(
  WidgetTester tester,
  _FakeTouchApi api,
  ProjectionStack stack,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: ProjectionTouchSurface(
            stack: stack,
            textureId: 1,
            bufferWidth: 1920,
            bufferHeight: 1080,
            enabled: true,
            touchApi: api,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  expect(tester.takeException(), isNull);
}

class _Send {
  _Send(this.action, this.actionIndex, this.pointerIds);

  final int action;
  final int actionIndex;
  final List<int> pointerIds;
}

class _FakeTouchApi extends ProjectionTouchApi {
  final List<_Send> sends = [];

  @override
  Future<ProjectionTouchStatus> bind(ProjectionStack stack) async =>
      ProjectionTouchStatus.empty;

  @override
  Future<ProjectionTouchStatus> unbind(ProjectionStack stack) async =>
      ProjectionTouchStatus.empty;

  @override
  Future<ProjectionTouchStatus> setBufferSize(
    ProjectionStack stack,
    int width,
    int height,
  ) async => ProjectionTouchStatus.empty;

  @override
  Future<ProjectionTouchResult> send({
    required ProjectionStack stack,
    required int action,
    required List<ProjectionTouchPointer> pointers,
    int actionIndex = 0,
  }) async {
    sends.add(_Send(action, actionIndex, [for (final p in pointers) p.id]));
    return ProjectionTouchResult.notSent;
  }
}
