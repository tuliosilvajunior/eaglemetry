import 'dart:async';
import 'dart:io';

import 'package:capy_companion/pairing/device_pairing_gateway.dart';
import 'package:capy_companion/sync/pairing_controller.dart';
import 'package:capy_companion/sync/pairing_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/backend_reachability.dart';

import 'support/fake_device_pairing_gateway.dart';

void main() {
  test('six digits pair the store via gateway and persist vehicle', () async {
    final store = PairingStore();
    final gateway = FakeDevicePairingGateway(
      claimResult: const ClaimResult.success(
        ClaimSuccess(vehicleId: 'v-1', accountId: 'a-1'),
      ),
    );
    final controller = PairingController(store: store, gateway: gateway);
    await controller.submit('847291');
    expect(controller.isPaired, isTrue);
    expect(store.current?.vehicleId, 'v-1');
    expect(store.current?.accountId, 'a-1');
    expect(controller.error, isNull);
    expect(controller.lastResult, isA<ClaimSuccessResult>());
    expect(controller.signedOut, isFalse);
    expect(gateway.lastUserCode, '847291');
  });

  test('non-digits are stripped before the length check', () async {
    final gateway = FakeDevicePairingGateway();
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
    );
    await controller.submit('847-291');
    expect(controller.isPaired, isTrue);
    expect(gateway.lastUserCode, '847291');
  });

  test('invalid length sets invalidCode and does not call gateway', () async {
    final gateway = FakeDevicePairingGateway();
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
    );
    await controller.submit('12');
    expect(controller.isPaired, isFalse);
    expect(controller.error, PairingError.invalidCode);
    expect(controller.lastResult, isNull);
    expect(gateway.claimCount, 0);
  });

  test('submit is code-only and still pairs', () async {
    final gateway = FakeDevicePairingGateway();
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
    );
    await controller.submit('847291');
    expect(controller.isPaired, isTrue);
    expect(controller.error, isNull);
    expect(gateway.claimCount, 1);
  });

  test('ClaimNotFound preserves distinct outcome', () async {
    final gateway = FakeDevicePairingGateway(
      claimResult: const ClaimResult.notFound(),
    );
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
    );
    await controller.submit('847291');
    expect(controller.isPaired, isFalse);
    expect(controller.lastResult, isA<ClaimNotFound>());
    expect(controller.error, PairingError.rejected);
    expect(controller.signedOut, isFalse);
  });

  test('ClaimExpired preserves distinct outcome', () async {
    final gateway = FakeDevicePairingGateway(
      claimResult: const ClaimResult.expired(),
    );
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
    );
    await controller.submit('847291');
    expect(controller.lastResult, isA<ClaimExpired>());
    expect(controller.error, PairingError.rejected);
    expect(controller.isPaired, isFalse);
  });

  test('ClaimAlreadyClaimed preserves distinct outcome', () async {
    final gateway = FakeDevicePairingGateway(
      claimResult: const ClaimResult.alreadyClaimed(),
    );
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
    );
    await controller.submit('847291');
    expect(controller.lastResult, isA<ClaimAlreadyClaimed>());
    expect(controller.error, PairingError.rejected);
    expect(controller.isPaired, isFalse);
  });

  test('ClaimVehicleAlreadyClaimed preserves distinct outcome', () async {
    final gateway = FakeDevicePairingGateway(
      claimResult: const ClaimResult.vehicleAlreadyClaimed(),
    );
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
    );
    await controller.submit('847291');
    expect(controller.lastResult, isA<ClaimVehicleAlreadyClaimed>());
    expect(controller.error, PairingError.rejected);
    expect(controller.isPaired, isFalse);
  });

  test('ClaimNetwork maps to carMissing but preserves lastResult', () async {
    final gateway = FakeDevicePairingGateway(
      claimResult: const ClaimResult.network(),
    );
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
    );
    await controller.submit('847291');
    expect(controller.lastResult, isA<ClaimNetwork>());
    expect(controller.error, PairingError.carMissing);
    expect(controller.isPaired, isFalse);
  });

  test('ClaimUnknown preserves distinct outcome', () async {
    final gateway = FakeDevicePairingGateway(
      claimResult: const ClaimResult.unknown(),
    );
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
    );
    await controller.submit('847291');
    expect(controller.lastResult, isA<ClaimUnknown>());
    expect(controller.error, PairingError.rejected);
    expect(controller.isPaired, isFalse);
  });

  test('ClaimAlreadyOwnedBySelf is SUCCESS even if car offline', () async {
    final store = PairingStore();
    // Pre-pair to have something to reuse on idempotent success.
    await store.completeClaim(vehicleId: 'v-1', accountId: 'a-1');
    final gateway = FakeDevicePairingGateway(
      claimResult: const ClaimResult.alreadyOwnedBySelf(),
    );
    final controller = PairingController(store: store, gateway: gateway);
    await controller.submit('847291');
    expect(controller.lastResult, isA<ClaimAlreadyOwnedBySelf>());
    expect(controller.error, isNull);
    expect(controller.signedOut, isFalse);
    // Idempotent success keeps paired (car may be offline, still success).
    expect(controller.isPaired, isTrue);
  });

  test('signed-out is distinct state, no gateway call, no crash', () async {
    final gateway = FakeDevicePairingGateway();
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
      isSignedIn: () => false,
    );
    await controller.submit('847291');
    expect(controller.signedOut, isTrue);
    expect(controller.error, isNull);
    expect(controller.lastResult, isNull);
    expect(controller.isPaired, isFalse);
    expect(gateway.claimCount, 0);
    expect(controller.busy, isFalse);
  });

  test('signed-out then successful claim clears signedOut', () async {
    final gateway = FakeDevicePairingGateway();
    var signedIn = false;
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
      isSignedIn: () => signedIn,
    );
    await controller.submit('847291');
    expect(controller.signedOut, isTrue);
    signedIn = true;
    await controller.submit('847291');
    expect(controller.signedOut, isFalse);
    expect(controller.isPaired, isTrue);
    expect(controller.lastResult, isA<ClaimSuccessResult>());
  });

  test('pairing survives reload from disk', () async {
    final dir = await Directory.systemTemp.createTemp('pairing-claim');
    addTearDown(() => dir.delete(recursive: true));
    final store = PairingStore(directory: dir);
    final gateway = FakeDevicePairingGateway(
      claimResult: const ClaimResult.success(
        ClaimSuccess(vehicleId: 'v-reload', accountId: 'a-reload'),
      ),
    );
    final controller = PairingController(store: store, gateway: gateway);
    await controller.submit('847291');

    final reloaded = PairingStore(directory: dir);
    await reloaded.load();
    expect(reloaded.isPaired, isTrue);
    expect(reloaded.current?.vehicleId, 'v-reload');
    expect(reloaded.current?.accountId, 'a-reload');
  });

  test('busy flag toggles around claim', () async {
    final completer = Completer<ClaimResult>();
    final gateway = _CompleterGateway(completer.future);
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
    );
    expect(controller.busy, isFalse);
    final future = controller.submit('847291');
    // The gateway hasn't completed yet, so busy must be true while pending.
    expect(controller.busy, isTrue);
    expect(controller.lastResult, isNull);
    completer.complete(
      const ClaimResult.success(ClaimSuccess(vehicleId: 'v1', accountId: 'a1')),
    );
    await future;
    expect(controller.busy, isFalse);
    expect(controller.isPaired, isTrue);
  });

  test('unpair clears the store and resets distinct states', () async {
    final store = PairingStore();
    final controller = PairingController(
      store: store,
      gateway: FakeDevicePairingGateway(),
    );
    await controller.submit('847291');
    expect(controller.isPaired, isTrue);
    await controller.unpair();
    expect(controller.isPaired, isFalse);
    expect(store.current, isNull);
    expect(controller.error, isNull);
    expect(controller.lastResult, isNull);
    expect(controller.signedOut, isFalse);
  });

  group('connectivity gate', () {
    test('connectivity is null before first check', () {
      final controller = PairingController(store: PairingStore());
      expect(controller.connectivity, isNull);
    });

    test(
      'noNetwork blocks gateway, sets connectivity, preserves claim fields',
      () async {
        final gateway = FakeDevicePairingGateway();
        final controller = PairingController(
          store: PairingStore(),
          gateway: gateway,
          reachabilityChecker: _FixedChecker(BackendReachability.noNetwork),
        );
        await controller.submit('847291');
        expect(controller.connectivity, BackendReachability.noNetwork);
        expect(gateway.claimCount, 0);
        expect(controller.busy, isFalse);
        expect(controller.error, isNull);
        expect(controller.lastResult, isNull);
        expect(controller.signedOut, isFalse);
        expect(controller.isPaired, isFalse);
      },
    );

    test('backendUnreachable blocks gateway, sets connectivity', () async {
      final gateway = FakeDevicePairingGateway();
      final controller = PairingController(
        store: PairingStore(),
        gateway: gateway,
        reachabilityChecker: _FixedChecker(
          BackendReachability.backendUnreachable,
        ),
      );
      await controller.submit('847291');
      expect(controller.connectivity, BackendReachability.backendUnreachable);
      expect(gateway.claimCount, 0);
      expect(controller.busy, isFalse);
      expect(controller.error, isNull);
      expect(controller.lastResult, isNull);
      expect(controller.signedOut, isFalse);
    });

    test('reachable allows normal claim flow', () async {
      final gateway = FakeDevicePairingGateway(
        claimResult: const ClaimResult.success(
          ClaimSuccess(vehicleId: 'v-1', accountId: 'a-1'),
        ),
      );
      final controller = PairingController(
        store: PairingStore(),
        gateway: gateway,
        reachabilityChecker: _FixedChecker(BackendReachability.reachable),
      );
      await controller.submit('847291');
      expect(controller.connectivity, BackendReachability.reachable);
      expect(gateway.claimCount, 1);
      expect(controller.isPaired, isTrue);
      expect(controller.error, isNull);
      expect(controller.lastResult, isA<ClaimSuccessResult>());
      expect(controller.busy, isFalse);
    });

    test(
      'reachable with claim failure still reflects connectivity then error',
      () async {
        final gateway = FakeDevicePairingGateway(
          claimResult: const ClaimResult.notFound(),
        );
        final controller = PairingController(
          store: PairingStore(),
          gateway: gateway,
          reachabilityChecker: _FixedChecker(BackendReachability.reachable),
        );
        await controller.submit('847291');
        expect(controller.connectivity, BackendReachability.reachable);
        expect(controller.lastResult, isA<ClaimNotFound>());
        expect(controller.error, PairingError.rejected);
        expect(gateway.claimCount, 1);
      },
    );

    test('no checker injected skips gate (existing tests unchanged)', () async {
      final gateway = FakeDevicePairingGateway();
      final controller = PairingController(
        store: PairingStore(),
        gateway: gateway,
      );
      await controller.submit('847291');
      expect(controller.isPaired, isTrue);
      expect(gateway.claimCount, 1);
      // connectivity stays null when no checker was provided
      expect(controller.connectivity, isNull);
    });

    test('unpair resets connectivity to null', () async {
      final gateway = FakeDevicePairingGateway();
      final controller = PairingController(
        store: PairingStore(),
        gateway: gateway,
        reachabilityChecker: _FixedChecker(BackendReachability.reachable),
      );
      await controller.submit('847291');
      expect(controller.connectivity, BackendReachability.reachable);
      await controller.unpair();
      expect(controller.connectivity, isNull);
    });

    test('invalid code does not probe connectivity', () async {
      final checker = _CountingChecker(BackendReachability.noNetwork);
      final gateway = FakeDevicePairingGateway();
      final controller = PairingController(
        store: PairingStore(),
        gateway: gateway,
        reachabilityChecker: checker,
      );
      await controller.submit('12');
      expect(checker.calls, 0);
      expect(controller.error, PairingError.invalidCode);
      expect(gateway.claimCount, 0);
    });

    test('signed-out blocks before connectivity probe', () async {
      final checker = _CountingChecker(BackendReachability.noNetwork);
      final gateway = FakeDevicePairingGateway();
      final controller = PairingController(
        store: PairingStore(),
        gateway: gateway,
        isSignedIn: () => false,
        reachabilityChecker: checker,
      );
      await controller.submit('847291');
      expect(checker.calls, 0);
      expect(controller.signedOut, isTrue);
      expect(gateway.claimCount, 0);
    });

    test('via real BackendReachabilityChecker with fake client', () async {
      // Proves the seam works with ReachabilityClient fake, not only fixed checker.
      final fakeClient = _FakeReachabilityClient(
        response: const ReachabilityResponse(
          statusCode: 200,
          body: '{"ok":true}',
        ),
      );
      final checker = BackendReachabilityChecker(
        client: fakeClient,
        backendUri: Uri.parse('https://example.supabase.co'),
      );
      final gateway = FakeDevicePairingGateway();
      final controller = PairingController(
        store: PairingStore(),
        gateway: gateway,
        reachabilityChecker: checker,
      );
      await controller.submit('847291');
      expect(fakeClient.calls, 1);
      expect(controller.connectivity, BackendReachability.reachable);
      expect(gateway.claimCount, 1);
    });

    test(
      'concurrent submits while checking connectivity only claim once',
      () async {
        final gateway = FakeDevicePairingGateway();
        final checker = _DelayedChecker(
          BackendReachability.reachable,
          delay: const Duration(milliseconds: 80),
        );
        final controller = PairingController(
          store: PairingStore(),
          gateway: gateway,
          reachabilityChecker: checker,
        );
        final f1 = controller.submit('847291');
        final f2 = controller.submit('847291');
        await Future.wait([f1, f2]);
        expect(gateway.claimCount, 1);
        expect(controller.connectivity, BackendReachability.reachable);
        expect(controller.busy, isFalse);
      },
    );
  });

  test(
    'concurrent submits race — only one claim (busy guard + checker gap)',
    () async {
      final gateway = _DelayedGateway(
        const ClaimResult.success(
          ClaimSuccess(vehicleId: 'v1', accountId: 'a1'),
        ),
        delay: const Duration(milliseconds: 80),
      );
      final checker = _DelayedChecker(
        BackendReachability.reachable,
        delay: const Duration(milliseconds: 30),
      );
      final controller = PairingController(
        store: PairingStore(),
        gateway: gateway,
        reachabilityChecker: checker,
      );
      // Two rapid taps before the first checker/claim completes.
      final f1 = controller.submit('123456');
      final f2 = controller.submit('123456');
      await Future.wait([f1, f2]);
      expect(
        gateway.claimCount,
        1,
        reason: 'second concurrent submit must be suppressed by busy guard',
      );
      expect(controller.isPaired, isTrue);
      expect(controller.busy, isFalse);
    },
  );

  test('concurrent submits without checker — only one claim', () async {
    final gateway = _DelayedGateway(
      const ClaimResult.success(ClaimSuccess(vehicleId: 'v1', accountId: 'a1')),
      delay: const Duration(milliseconds: 60),
    );
    final controller = PairingController(
      store: PairingStore(),
      gateway: gateway,
    );
    final f1 = controller.submit('123456');
    final f2 = controller.submit('123456');
    await Future.wait([f1, f2]);
    expect(gateway.claimCount, 1);
  });
}

class _CompleterGateway implements DevicePairingGateway {
  _CompleterGateway(this.future);

  final Future<ClaimResult> future;
  int claimCount = 0;

  @override
  Future<ClaimResult> claim(String userCode) {
    claimCount++;
    return future;
  }
}

class _DelayedGateway implements DevicePairingGateway {
  _DelayedGateway(this.result, {required this.delay});
  final ClaimResult result;
  final Duration delay;
  int claimCount = 0;
  @override
  Future<ClaimResult> claim(String userCode) async {
    claimCount++;
    await Future.delayed(delay);
    return result;
  }
}

class _DelayedChecker extends BackendReachabilityChecker {
  _DelayedChecker(this.result, {required this.delay})
    : super(
        client: _NoOpClient(),
        backendUri: Uri.parse('https://example.supabase.co'),
      );
  final BackendReachability result;
  final Duration delay;
  @override
  Future<BackendReachability> check() async {
    await Future.delayed(delay);
    return result;
  }
}

class _FixedChecker extends BackendReachabilityChecker {
  _FixedChecker(this.result)
    : super(
        client: _NoOpClient(),
        backendUri: Uri.parse('https://example.supabase.co'),
      );

  final BackendReachability result;

  @override
  Future<BackendReachability> check() async => result;
}

class _CountingChecker extends BackendReachabilityChecker {
  _CountingChecker(this.result)
    : super(
        client: _NoOpClient(),
        backendUri: Uri.parse('https://example.supabase.co'),
      );

  final BackendReachability result;
  int calls = 0;

  @override
  Future<BackendReachability> check() async {
    calls++;
    return result;
  }
}

class _FakeReachabilityClient implements ReachabilityClient {
  _FakeReachabilityClient({this.response});

  ReachabilityResponse? response;
  Object? exception;
  int calls = 0;

  @override
  Future<ReachabilityResponse> get(
    Uri uri, {
    required Duration timeout,
    Map<String, String>? headers,
  }) async {
    calls++;
    if (exception != null) {
      Error.throwWithStackTrace(exception!, StackTrace.current);
    }
    return response ?? const ReachabilityResponse(statusCode: 200);
  }
}

class _NoOpClient implements ReachabilityClient {
  @override
  Future<ReachabilityResponse> get(
    Uri uri, {
    required Duration timeout,
    Map<String, String>? headers,
  }) async => const ReachabilityResponse(statusCode: 200, body: '{"ok":true}');
}
