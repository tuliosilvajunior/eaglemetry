import 'dart:async';

import 'package:capy_companion/auth/account_gateway.dart';

/// An account server that answers from a map, so a test needs no network.
class FakeAccountGateway implements AccountGateway {
  FakeAccountGateway({
    this.accepts = 'reader@example.com',
    this.password = 'sixchars',
    this.confirmsByMail = false,
    AccountSession? existing,
  }) : current = existing;

  final String accepts;
  final String password;

  /// Whether a sign-up leaves the address unconfirmed, which is what a project
  /// with mail confirmation on does.
  final bool confirmsByMail;

  @override
  AccountSession? current;

  int resetCount = 0;

  final _changes = StreamController<AccountSession?>.broadcast();

  @override
  Stream<AccountSession?> get changes => _changes.stream;

  /// Stands in for the confirmation link landing on the phone.
  void confirm(String email) {
    current = AccountSession(email: email, confirmed: true);
    _changes.add(current);
  }

  @override
  Future<AccountSession> signIn({
    required String email,
    required String password,
  }) async {
    if (email != accepts || password != this.password) {
      throw const AccountFailure(AccountError.wrongCredentials);
    }
    return current = AccountSession(email: email, confirmed: true);
  }

  @override
  Future<AccountSession> signUp({
    required String email,
    required String password,
  }) async {
    if (email == accepts) {
      throw const AccountFailure(AccountError.alreadyRegistered);
    }
    final session = AccountSession(email: email, confirmed: !confirmsByMail);
    if (session.confirmed) current = session;
    return session;
  }

  @override
  Future<void> sendPasswordReset(String email) async {
    resetCount++;
  }

  @override
  Future<void> signOut() async {
    current = null;
  }
}
