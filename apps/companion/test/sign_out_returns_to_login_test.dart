import 'package:capy_companion/auth/account_gateway.dart';
import 'package:capy_companion/auth/auth_controller.dart';
import 'package:capy_companion/main.dart';
import 'package:capy_companion/onboarding/onboarding_flow.dart';
import 'package:capy_companion/onboarding/onboarding_store.dart';
import 'package:capy_companion/pairing/device_pairing_gateway.dart';
import 'package:capy_companion/screens/home_screen.dart';
import 'package:capy_companion/sync/pairing_controller.dart';
import 'package:capy_companion/sync/pairing_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_account_gateway.dart';
import 'support/fake_device_pairing_gateway.dart';

const _signedIn = AccountSession(email: 'reader@example.com', confirmed: true);

Future<PairingController> _paired() async {
  final controller = PairingController(
    store: PairingStore(),
    gateway: FakeDevicePairingGateway(
      claimResult: const ClaimResult.success(
        ClaimSuccess(vehicleId: 'v1', accountId: 'a1'),
      ),
    ),
  );
  await controller.submit('123456');
  return controller;
}

Future<OnboardingStore> _seenStore() async {
  final store = OnboardingStore();
  await store.markSeen();
  return store;
}

void main() {
  testWidgets('signing out puts the account door back in front of the app', (
    tester,
  ) async {
    final auth = AuthController(FakeAccountGateway(existing: _signedIn))
      ..restore();

    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: await _paired(),
        auth: auth,
        onboarding: await _seenStore(),
      ),
    );
    await tester.pumpAndSettle();

    // Signed in: the app itself.
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OnboardingFlow), findsNothing);

    await auth.signOut();
    await tester.pumpAndSettle();

    // Signed out: the door. Not a settings screen with an empty account card.
    expect(find.byType(OnboardingFlow), findsOneWidget);
    expect(find.byKey(const Key('onboarding-login')), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);

    // No slides behind it. The reader has seen them and did not ask to leave
    // the app, only the account.
    expect(find.byKey(const Key('onboarding-login-back')), findsNothing);
  });

  testWidgets('signing back in returns the app, without pairing again', (
    tester,
  ) async {
    final gateway = FakeAccountGateway();
    final auth = AuthController(gateway);

    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: await _paired(),
        auth: auth,
        onboarding: await _seenStore(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('onboarding-login')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('onboarding-email-field')),
      'reader@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('onboarding-password-field')),
      'sixchars',
    );
    await tester.tap(find.byKey(const Key('onboarding-account-submit')));
    await tester.pumpAndSettle();

    // Straight back to the app: the car was never unpaired, so the journey
    // must not walk the reader through pairing it again.
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byKey(const Key('onboarding-pair')), findsNothing);
  });

  testWidgets('a build with no account server never shows the door', (
    tester,
  ) async {
    await tester.pumpWidget(
      CompanionApp(
        locale: const Locale('en'),
        pairing: await _paired(),
        onboarding: await _seenStore(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingFlow), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
