import 'package:capy_companion/main.dart';
import 'package:capy_companion/pairing/device_pairing_gateway.dart';
import 'package:capy_companion/screens/home_screen.dart';
import 'package:capy_companion/sync/pairing_controller.dart';
import 'package:capy_companion/sync/pairing_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/backend_reachability.dart';

import 'support/fake_device_pairing_gateway.dart';

PairingController _controller({
  ClaimResult? claimResult,
  BackendReachability? connectivity,
  bool signedOut = false,
}) {
  final gateway = FakeDevicePairingGateway(
    claimResult:
        claimResult ??
        const ClaimResult.success(
          ClaimSuccess(vehicleId: 'v1', accountId: 'a1'),
        ),
  );
  final checker = connectivity == null ? null : _FixedChecker(connectivity);
  return PairingController(
    store: PairingStore(),
    gateway: gateway,
    reachabilityChecker: checker,
    isSignedIn: signedOut ? () => false : null,
  );
}

void main() {
  testWidgets('unpaired home shows the pairing form', (tester) async {
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: _controller()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Pair with the car'), findsOneWidget);
    expect(find.byKey(const Key('pairing-code-field')), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);
  });

  testWidgets('pairing form has no host field', (tester) async {
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: _controller()),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pairing-host-field')), findsNothing);
    expect(find.byKey(const Key('pairing-code-field')), findsOneWidget);
  });

  testWidgets('a short code is refused and does not pair', (tester) async {
    final pairing = _controller();
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('pairing-code-field')), '12');
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(find.text('Enter the 6 digits from the car.'), findsOneWidget);
    expect(pairing.isPaired, isFalse);
  });

  testWidgets('a valid code stores the secret and shows paired', (
    tester,
  ) async {
    final pairing = _controller();
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '123456',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(pairing.isPaired, isTrue);
    expect(find.text('Paired'), findsOneWidget);
    expect(find.text('Pair with the car'), findsNothing);
  });

  testWidgets('notFound shows distinct message', (tester) async {
    final pairing = _controller(claimResult: const ClaimResult.notFound());
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '000000',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(pairing.isPaired, isFalse);
    expect(
      find.text('Code not found. Check the code and try again.'),
      findsOneWidget,
    );
  });

  testWidgets('expired shows distinct message', (tester) async {
    final pairing = _controller(claimResult: const ClaimResult.expired());
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '000000',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(
      find.text('Code expired. Ask the car for a new code.'),
      findsOneWidget,
    );
  });

  testWidgets('alreadyClaimed shows distinct message', (tester) async {
    final pairing = _controller(
      claimResult: const ClaimResult.alreadyClaimed(),
    );
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '000000',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(
      find.text('Code already used. Ask the car for a new code.'),
      findsOneWidget,
    );
  });

  testWidgets('vehicleAlreadyClaimed shows distinct message', (tester) async {
    final pairing = _controller(
      claimResult: const ClaimResult.vehicleAlreadyClaimed(),
    );
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '000000',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(
      find.text('This vehicle is already paired to another account.'),
      findsOneWidget,
    );
  });

  testWidgets('network shows distinct message', (tester) async {
    final pairing = _controller(claimResult: const ClaimResult.network());
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '000000',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(find.text('Network error. Try again.'), findsOneWidget);
  });

  testWidgets('unknown shows distinct message', (tester) async {
    final pairing = _controller(claimResult: const ClaimResult.unknown());
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '000000',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong. Try again.'), findsOneWidget);
  });

  testWidgets('alreadyOwnedBySelf is success-equivalent', (tester) async {
    final pairing = PairingController(
      store: PairingStore(),
      gateway: FakeDevicePairingGateway(
        claimResult: const ClaimResult.alreadyOwnedBySelf(),
      ),
    );
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '123456',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    // Already owned by self is not an error; treated as success-equivalent.
    expect(find.byKey(const Key('pairing-error')), findsNothing);
    // No distinct error copy should appear.
    expect(
      find.text('Code not found. Check the code and try again.'),
      findsNothing,
    );
    expect(
      find.text('Code expired. Ask the car for a new code.'),
      findsNothing,
    );
    expect(find.text('Something went wrong. Try again.'), findsNothing);
    expect(pairing.lastResult, isA<ClaimAlreadyOwnedBySelf>());
    expect(pairing.error, isNull);
  });

  testWidgets('signedOut shows distinct message', (tester) async {
    final pairing = _controller(signedOut: true);
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '123456',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(find.text('Sign in to pair this car.'), findsOneWidget);
    expect(pairing.isPaired, isFalse);
  });

  testWidgets(
    'noNetwork shows distinct message with retry and no gateway call',
    (tester) async {
      final gateway = FakeDevicePairingGateway();
      final pairing = PairingController(
        store: PairingStore(),
        gateway: gateway,
        reachabilityChecker: _FixedChecker(BackendReachability.noNetwork),
      );
      await tester.pumpWidget(
        CompanionApp(locale: const Locale('en'), pairing: pairing),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('pairing-code-field')),
        '123456',
      );
      await tester.tap(find.text('Pair'));
      await tester.pumpAndSettle();

      expect(
        find.text('No internet. Check your connection and try again.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('pairing-retry')), findsOneWidget);
      expect(find.byKey(const Key('pairing-error')), findsOneWidget);
      expect(gateway.claimCount, 0);
      expect(pairing.isPaired, isFalse);
    },
  );

  testWidgets('backendUnreachable shows distinct message with retry', (
    tester,
  ) async {
    final gateway = FakeDevicePairingGateway();
    final pairing = PairingController(
      store: PairingStore(),
      gateway: gateway,
      reachabilityChecker: _FixedChecker(
        BackendReachability.backendUnreachable,
      ),
    );
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '123456',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(find.text('Can\'t reach the server. Try again.'), findsOneWidget);
    expect(find.byKey(const Key('pairing-retry')), findsOneWidget);
    expect(gateway.claimCount, 0);
  });

  testWidgets('retry after noNetwork re-checks connectivity', (tester) async {
    final gateway = FakeDevicePairingGateway();
    final checker = _SwitchingChecker([
      BackendReachability.noNetwork,
      BackendReachability.reachable,
    ]);
    final pairing = PairingController(
      store: PairingStore(),
      gateway: gateway,
      reachabilityChecker: checker,
    );
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '123456',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(
      find.text('No internet. Check your connection and try again.'),
      findsOneWidget,
    );
    expect(gateway.claimCount, 0);

    await tester.tap(find.byKey(const Key('pairing-retry')));
    await tester.pumpAndSettle();

    expect(pairing.isPaired, isTrue);
    expect(find.text('Paired'), findsOneWidget);
  });

  testWidgets('paired can unpair and returns to form', (tester) async {
    final pairing = _controller();
    await tester.pumpWidget(
      CompanionApp(locale: const Locale('en'), pairing: pairing),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('pairing-code-field')),
      '123456',
    );
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(pairing.isPaired, isTrue);
    expect(find.text('Paired'), findsOneWidget);

    await tester.tap(find.text('Forget this car'));
    await tester.pumpAndSettle();

    expect(pairing.isPaired, isFalse);
    expect(find.text('Pair with the car'), findsOneWidget);
    expect(find.byKey(const Key('pairing-code-field')), findsOneWidget);
  });
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

class _SwitchingChecker extends BackendReachabilityChecker {
  _SwitchingChecker(this.results)
    : super(
        client: _NoOpClient(),
        backendUri: Uri.parse('https://example.supabase.co'),
      );

  final List<BackendReachability> results;
  int _idx = 0;

  @override
  Future<BackendReachability> check() async {
    final r = results[_idx];
    if (_idx < results.length - 1) _idx++;
    return r;
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
