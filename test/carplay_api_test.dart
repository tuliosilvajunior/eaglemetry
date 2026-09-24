import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/carplay_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.timhss.capyenergy/carplay');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const fullMap = <String, Object?>{
    'available': true,
    'bound': true,
    'attached': true,
    'activityResumed': true,
    'dartActive': true,
    'textureId': 7,
    'bufferWidth': 1920,
    'bufferHeight': 1080,
    'attachCount': 3,
    'lastError': null,
  };

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('CarplayStatus.fromMap', () {
    test('round-trips all 10 keys, textureId is an int', () {
      final status = CarplayStatus.fromMap(fullMap);
      expect(status.available, isTrue);
      expect(status.bound, isTrue);
      expect(status.attached, isTrue);
      expect(status.activityResumed, isTrue);
      expect(status.dartActive, isTrue);
      expect(status.textureId, isA<int>());
      expect(status.textureId, 7);
      expect(status.bufferWidth, 1920);
      expect(status.bufferHeight, 1080);
      expect(status.attachCount, 3);
      expect(status.lastError, isNull);
    });

    test('textureId null means canRender false', () {
      final status = CarplayStatus.fromMap({...fullMap, 'textureId': null});
      expect(status.textureId, isNull);
      expect(status.canRender, isFalse);
      expect(status.attached, isTrue);
    });

    test('missing keys default instead of throwing', () {
      final status = CarplayStatus.fromMap(const {});
      expect(status, CarplayStatus.empty);
      final partial = CarplayStatus.fromMap(const {'available': true});
      expect(partial.available, isTrue);
      expect(partial.attached, isFalse);
      expect(partial.textureId, isNull);
      expect(partial.bufferWidth, 0);
      expect(partial.lastError, isNull);
    });

    test('bufferAspect at 1920x1080 is 16:9', () {
      final status = CarplayStatus.fromMap(fullMap);
      expect(status.bufferAspect, closeTo(16 / 9, 1e-9));
    });

    test('bufferAspect at 0x0 falls back to 16:9, never NaN', () {
      final status = CarplayStatus.fromMap(const {
        'bufferWidth': 0,
        'bufferHeight': 0,
      });
      expect(status.bufferAspect, 16 / 9);
      expect(status.bufferAspect.isFinite, isTrue);
    });

    test('canRender truth table over attached x textureId', () {
      for (final attached in [true, false]) {
        for (final hasTexture in [true, false]) {
          final status = CarplayStatus.fromMap({
            ...fullMap,
            'attached': attached,
            'textureId': hasTexture ? 1 : null,
          });
          expect(
            status.canRender,
            attached && hasTexture,
            reason: 'attached=$attached texture=$hasTexture',
          );
        }
      }
    });
  });

  group('CarplayApi channel calls', () {
    late CarplayApi api;

    setUp(() {
      api = CarplayApi();
    });

    test('activate(width, height) sends the method and the args map', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return fullMap;
      });

      final status = await api.activate(width: 1920, height: 1080);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'activate');
      expect(calls.single.arguments, {'width': 1920, 'height': 1080});
      expect(status.textureId, 7);
    });

    test(
      'activate() with no arguments sends nulls for the native default',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return fullMap;
        });

        await api.activate();

        expect(calls, hasLength(1));
        expect(calls.single.method, 'activate');
        final args = calls.single.arguments as Map<Object?, Object?>;
        expect(args['width'], isNull);
        expect(args['height'], isNull);
      },
    );

    test('deactivate and refresh use their own method names', () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return fullMap;
      });

      await api.deactivate();
      await api.refresh();
      await api.getStatus();

      expect(methods, ['deactivate', 'refresh', 'getStatus']);
    });

    test(
      'PlatformException returns a status with lastError, no rethrow',
      () async {
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => throw PlatformException(code: 'REMOTE_EXCEPTION'),
        );

        final status = await api.activate();

        expect(status.lastError, 'REMOTE_EXCEPTION');
      },
    );

    test('keeps the previously known state when the channel throws', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => fullMap);
      final ok = await api.activate();
      expect(ok.attached, isTrue);

      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'BINDING_DIED'),
      );
      final failed = await api.refresh();

      expect(failed.attached, isTrue, reason: 'known state must survive');
      expect(failed.lastError, 'BINDING_DIED');
    });
  });
}
