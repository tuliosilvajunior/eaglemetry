import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'account_gateway.dart';
import 'supabase_config.dart';

/// The one file in the app that knows the provider is Supabase.
///
/// Everything above it speaks [AccountGateway] and [AccountError]. The
/// provider's own [AuthException] never leaves this class, because its
/// `message` is server text: it is not localized, it changes between releases
/// of the service, and it must not reach a screen.
class SupabaseAccountGateway implements AccountGateway {
  SupabaseAccountGateway(this._auth);

  /// Starts the client and answers the gateway, or null when this build
  /// carries no project. The caller decides what a missing project means; a
  /// gateway that could not connect must not pretend to be one.
  static Future<SupabaseAccountGateway?> start() async {
    if (!SupabaseConfig.isConfigured) return null;
    await Supabase.initialize(
      url: SupabaseConfig.url,
      publishableKey: SupabaseConfig.publishableKey,
    );
    return SupabaseAccountGateway(Supabase.instance.client.auth);
  }

  final GoTrueClient _auth;

  @override
  AccountSession? get current {
    final user = _auth.currentSession?.user;
    if (user == null) return null;
    return AccountSession(
      email: user.email ?? '',
      confirmed: user.emailConfirmedAt != null,
    );
  }

  @override
  Stream<AccountSession?> get changes => _auth.onAuthStateChange.map((_) {
    return current;
  });

  @override
  Future<AccountSession> signIn({
    required String email,
    required String password,
  }) {
    return _guard(() async {
      final response = await _auth.signInWithPassword(
        email: email,
        password: password,
      );
      final user = response.user;
      if (user == null) throw const AccountFailure(AccountError.unknown);
      return AccountSession(
        email: user.email ?? email,
        confirmed: user.emailConfirmedAt != null,
      );
    });
  }

  @override
  Future<AccountSession> signUp({
    required String email,
    required String password,
  }) {
    return _guard(() async {
      final response = await _auth.signUp(
        email: email,
        password: password,
        emailRedirectTo: SupabaseConfig.redirectUrl,
      );
      final user = response.user;
      if (user == null) throw const AccountFailure(AccountError.unknown);
      // A project that confirms by mail answers with a user and no session.
      // That is a real sign-up and not a sign-in, so it is reported as
      // unconfirmed rather than as a failure.
      return AccountSession(
        email: user.email ?? email,
        confirmed: response.session != null && user.emailConfirmedAt != null,
      );
    });
  }

  @override
  Future<void> sendPasswordReset(String email) {
    return _guard(
      () => _auth.resetPasswordForEmail(
        email,
        redirectTo: SupabaseConfig.redirectUrl,
      ),
    );
  }

  @override
  Future<void> signOut() => _guard(() => _auth.signOut());

  /// Turns every way the provider can fail into an [AccountFailure].
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AccountFailure {
      rethrow;
    } on AuthException catch (error) {
      throw AccountFailure(_map(error), error.message);
    } on SocketException catch (error) {
      throw AccountFailure(AccountError.network, error.message);
    } on TimeoutException catch (error) {
      throw AccountFailure(AccountError.network, error.message);
    } on Object catch (error) {
      throw AccountFailure(AccountError.unknown, '$error');
    }
  }

  /// Reads the machine-readable `code`, not the message.
  AccountError _map(AuthException error) {
    final msg = error.message.toLowerCase();
    final isPasswordError = msg.contains('password') || msg.contains('senha');
    final isEmailError =
        msg.contains('email') ||
        msg.contains('address') ||
        msg.contains('endereço');

    return switch (error.code) {
      'invalid_credentials' || 'invalid_grant' => AccountError.wrongCredentials,
      'email_not_confirmed' => AccountError.emailNotConfirmed,
      'user_already_exists' || 'email_exists' => AccountError.alreadyRegistered,
      'weak_password' => AccountError.weakPassword,
      'validation_failed' =>
        isPasswordError
            ? AccountError.weakPassword
            : (isEmailError
                  ? AccountError.invalidEmail
                  : AccountError.weakPassword),
      'over_request_rate_limit' ||
      'over_email_send_rate_limit' => AccountError.rateLimited,
      _ =>
        isPasswordError
            ? AccountError.weakPassword
            : (isEmailError
                  ? AccountError.invalidEmail
                  : (error.statusCode == '400'
                        ? AccountError.wrongCredentials
                        : AccountError.unknown)),
    };
  }
}
