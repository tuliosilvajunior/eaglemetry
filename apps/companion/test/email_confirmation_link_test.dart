import 'package:capy_companion/auth/auth_controller.dart';
import 'package:capy_companion/auth/supabase_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_account_gateway.dart';

void main() {
  test('the confirmation link signs the reader in with no press', () async {
    final gateway = FakeAccountGateway(confirmsByMail: true);
    final controller = AuthController(gateway);
    var rebuilds = 0;
    controller.addListener(() => rebuilds++);

    await controller.signUp('new@example.com', 'Pass123');
    expect(controller.notice, AccountNotice.confirmEmail);
    expect(controller.isSignedIn, isFalse);

    // The reader leaves the app, taps the link in the mail, and the phone
    // hands it back through the custom scheme.
    gateway.confirm('new@example.com');
    await Future<void>.delayed(Duration.zero);

    expect(controller.isSignedIn, isTrue);
    expect(controller.notice, isNull);
    expect(rebuilds, greaterThan(0));
    controller.dispose();
  });

  test('the redirect matches the scheme the two platforms declare', () {
    // Three declarations of one address. This test is the fourth reader, and
    // it exists because a mismatch fails silently in a browser tab.
    expect(SupabaseConfig.redirectUrl, 'eaglemetry://auth-callback');
  });
}
