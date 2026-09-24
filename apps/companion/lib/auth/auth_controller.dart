import 'dart:async';

import 'package:flutter/foundation.dart';

import 'account_gateway.dart';

/// Something that happened and is not a failure.
///
/// Kept apart from [AccountError] because the two are drawn differently and
/// mean opposite things. A reset mail that went out is good news; folding it
/// into the error slot would paint it red.
enum AccountNotice {
  /// The sign-up was accepted and the address has to answer its mail before
  /// it can sign in.
  confirmEmail,

  /// The reset mail was sent, if that address has an account.
  resetSent,
}

/// Owns the login form. The screen only draws it.
///
/// The same shape as [PairingController]: one busy flag, one reason the last
/// action failed, and no widget state of its own. A screen that is rebuilt or
/// dropped must not be able to lose what the last attempt did.
class AuthController extends ChangeNotifier {
  AuthController(this.gateway) {
    _watch = gateway?.changes.listen(_adopt);
  }

  /// Null when this build carries no project. Every action then refuses with
  /// [AccountError.unconfigured] instead of throwing, so the screen can say
  /// what is missing.
  final AccountGateway? gateway;

  bool busy = false;
  AccountError? error;
  AccountNotice? notice;

  AccountSession? session;

  /// The address that is signed in, or null.
  bool get isSignedIn => session?.confirmed ?? false;

  /// The shortest password the server accepts. Refused here as well as there,
  /// so a reader who types four characters is told before a round trip.
  static const minPasswordLength = 6;

  static final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  static final _hasUppercase = RegExp(r'[A-Z]');
  static final _hasLowercase = RegExp(r'[a-z]');
  static final _hasDigit = RegExp(r'[0-9]');

  /// Whether a password meets the policy requirements (minimum length,
  /// uppercase letter, lowercase letter, and digit).
  static bool isPasswordValid(String password) {
    return password.length >= minPasswordLength &&
        _hasUppercase.hasMatch(password) &&
        _hasLowercase.hasMatch(password) &&
        _hasDigit.hasMatch(password);
  }

  StreamSubscription<AccountSession?>? _watch;

  /// Takes a session the gateway reports on its own.
  ///
  /// This is the confirmation mail landing: the reader tapped a link outside
  /// the app and came back signed in. It clears [notice] only when the session
  /// is confirmed, because the one notice this can answer is
  /// [AccountNotice.confirmEmail], and a stream event that says nothing new
  /// must not wipe a line the reader has not read yet.
  void _adopt(AccountSession? incoming) {
    if (incoming == null && session == null) return;
    session = incoming;
    if (incoming?.confirmed ?? false) {
      notice = null;
      error = null;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _watch?.cancel();
    super.dispose();
  }

  Future<void> signIn(String email, String password) {
    return _run(
      email: email,
      password: password,
      validateComplexity: false,
      action: (gateway, address) =>
          gateway.signIn(email: address, password: password),
    );
  }

  Future<void> signUp(String email, String password) {
    return _run(
      email: email,
      password: password,
      validateComplexity: true,
      action: (gateway, address) =>
          gateway.signUp(email: address, password: password),
    );
  }

  /// Sends the reset mail. It reports [AccountNotice.resetSent] whatever the
  /// server found, because the server does not say whether the address has an
  /// account and this app must not answer that for it.
  Future<void> sendPasswordReset(String email) async {
    if (busy) return;
    final address = email.trim();
    if (!_emailPattern.hasMatch(address)) {
      error = AccountError.invalidEmail;
      notice = null;
      notifyListeners();
      return;
    }
    final store = gateway;
    if (store == null) {
      error = AccountError.unconfigured;
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      await store.sendPasswordReset(address);
      notice = AccountNotice.resetSent;
    } on AccountFailure catch (failure) {
      error = failure.error;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    await gateway?.signOut();
    session = null;
    error = null;
    notice = null;
    notifyListeners();
  }

  /// Adopts a session the gateway already held from an earlier run, so a
  /// reader who signed in last week is not asked again.
  void restore() {
    session = gateway?.current;
    if (session != null) notifyListeners();
  }

  Future<void> _run({
    required String email,
    required String password,
    required Future<AccountSession> Function(AccountGateway, String) action,
    bool validateComplexity = false,
  }) async {
    if (busy) return;
    final address = email.trim();
    if (!_emailPattern.hasMatch(address)) {
      error = AccountError.invalidEmail;
      notice = null;
      notifyListeners();
      return;
    }
    if (validateComplexity
        ? !isPasswordValid(password)
        : password.length < minPasswordLength) {
      error = AccountError.weakPassword;
      notice = null;
      notifyListeners();
      return;
    }
    final store = gateway;
    if (store == null) {
      error = AccountError.unconfigured;
      notice = null;
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notice = null;
    notifyListeners();
    try {
      final result = await action(store, address);
      session = result;
      // A sign-up on a project that confirms by mail lands here with a user
      // and no confirmation. It is not an error and it is not a sign-in: the
      // reader has one more thing to do, and is told what it is.
      notice = result.confirmed ? null : AccountNotice.confirmEmail;
    } on AccountFailure catch (failure) {
      error = failure.error;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
