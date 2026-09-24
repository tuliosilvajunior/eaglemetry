/// Who is signed in on this phone.
///
/// The account is an account, not a data route. Nothing in the archive is
/// uploaded and nothing is read back from the server: the car is still the
/// source, and the sync still runs over the home network between two devices.
/// A screen that shows the signed-in address must not imply otherwise.
class AccountSession {
  const AccountSession({required this.email, required this.confirmed});

  final String email;

  /// Whether the address answered its confirmation mail. A fresh sign-up on a
  /// project that confirms by mail returns no session, and the reader has to
  /// be told that rather than shown a screen that says they are in.
  final bool confirmed;
}

/// Why the last account action failed.
///
/// Each case is a different fact about what happened, and the screen prints a
/// different line for each. They are deliberately not folded into one
/// "failed": a wrong password, an unconfirmed address and an unreachable
/// server ask the reader for three different next steps.
enum AccountError {
  /// The text in the field is not an address.
  invalidEmail,

  /// The server refuses a password this short.
  weakPassword,

  /// The pair was refused.
  wrongCredentials,

  /// The address exists but never answered its confirmation mail.
  emailNotConfirmed,

  /// Sign-up on an address that already has an account.
  alreadyRegistered,

  /// Too many attempts in too short a time.
  rateLimited,

  /// The server was not reached.
  network,

  /// This build carries no project URL or key, so no account action can run.
  unconfigured,

  unknown,
}

/// Thrown by an [AccountGateway] instead of the provider's own exception type.
///
/// The provider stays behind this interface on purpose. The screens, the
/// controller and the tests all speak [AccountError]; only one file in the app
/// knows that the provider is Supabase, which is what keeps a change of
/// provider from being a change of every screen.
class AccountFailure implements Exception {
  const AccountFailure(this.error, [this.detail]);

  final AccountError error;

  /// The provider's own message, for a log. Never printed to the reader: it is
  /// written in the provider's words and in the provider's language.
  final String? detail;

  @override
  String toString() => 'AccountFailure($error, $detail)';
}

/// The account actions the journey needs. Four, and no more: the login screen
/// draws exactly these.
abstract interface class AccountGateway {
  /// The session this phone already holds, or null when nobody is signed in.
  AccountSession? get current;

  /// Fires when the session changes without this app asking.
  ///
  /// It exists for the confirmation mail. The reader leaves the app, taps the
  /// link, and the phone hands it back through the custom scheme; the sign-in
  /// then happens with no press inside the app. Without this stream the screen
  /// would keep saying "confirm your address" over a session that is already
  /// confirmed, until the reader closed the app and opened it again.
  Stream<AccountSession?> get changes;

  Future<AccountSession> signIn({
    required String email,
    required String password,
  });

  Future<AccountSession> signUp({
    required String email,
    required String password,
  });

  /// Sends the reset mail. It answers nothing about whether the address
  /// exists, because the server does not say, and inventing an answer here
  /// would tell a stranger which addresses have accounts.
  Future<void> sendPasswordReset(String email);

  Future<void> signOut();
}
