import 'package:capy_companion/auth/account_gateway.dart';
import 'package:capy_companion/auth/auth_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_account_gateway.dart';

void main() {
  test('text that is not an address never reaches the server', () async {
    final gateway = FakeAccountGateway();
    final auth = AuthController(gateway);

    await auth.signIn('reader', 'sixchars');

    expect(auth.error, AccountError.invalidEmail);
    expect(auth.session, isNull);
  });

  test('a password under the server minimum is refused here', () async {
    final auth = AuthController(FakeAccountGateway());

    await auth.signIn('reader@example.com', 'five5');

    expect(auth.error, AccountError.weakPassword);
  });

  test('a refused pair is reported as a refused pair', () async {
    final auth = AuthController(FakeAccountGateway());

    await auth.signIn('reader@example.com', 'wrongpass');

    expect(auth.error, AccountError.wrongCredentials);
    expect(auth.isSignedIn, isFalse);
  });

  test('a good pair opens the session', () async {
    final auth = AuthController(FakeAccountGateway());

    await auth.signIn('reader@example.com', 'sixchars');

    expect(auth.error, isNull);
    expect(auth.isSignedIn, isTrue);
    expect(auth.session!.email, 'reader@example.com');
  });

  test('a sign-up that waits for the mail is a notice, not an error', () async {
    final auth = AuthController(FakeAccountGateway(confirmsByMail: true));

    await auth.signUp('new@example.com', 'Pass123');

    expect(auth.error, isNull);
    expect(auth.notice, AccountNotice.confirmEmail);
    // The address exists and the reader is not in. The journey must not move
    // on: the next thing to do is open the mail.
    expect(auth.isSignedIn, isFalse);
  });

  test('sign-up validates password complexity', () async {
    final auth = AuthController(FakeAccountGateway());

    // No uppercase
    await auth.signUp('new@example.com', 'pass123');
    expect(auth.error, AccountError.weakPassword);

    // No lowercase
    await auth.signUp('new@example.com', 'PASS123');
    expect(auth.error, AccountError.weakPassword);

    // No digits
    await auth.signUp('new@example.com', 'Password');
    expect(auth.error, AccountError.weakPassword);

    // Too short
    await auth.signUp('new@example.com', 'Pa1');
    expect(auth.error, AccountError.weakPassword);

    // Valid (uppercase, lowercase, digit, >=6 chars)
    await auth.signUp('new@example.com', 'Pass123');
    expect(auth.error, isNull);
  });

  test(
    'the reset mail says nothing about whether the address exists',
    () async {
      final gateway = FakeAccountGateway();
      final auth = AuthController(gateway);

      await auth.sendPasswordReset('stranger@example.com');

      expect(gateway.resetCount, 1);
      expect(auth.notice, AccountNotice.resetSent);
      expect(auth.error, isNull);
    },
  );

  test('a build with no project refuses instead of throwing', () async {
    final auth = AuthController(null);

    await auth.signIn('reader@example.com', 'sixchars');

    expect(auth.error, AccountError.unconfigured);
  });

  test('a session from an earlier run is adopted', () {
    final auth = AuthController(
      FakeAccountGateway(
        existing: const AccountSession(
          email: 'reader@example.com',
          confirmed: true,
        ),
      ),
    );

    auth.restore();

    expect(auth.isSignedIn, isTrue);
  });
}
