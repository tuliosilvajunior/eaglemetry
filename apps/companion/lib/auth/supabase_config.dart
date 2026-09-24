/// Where the account server is.
///
/// Both values arrive from `apps/companion/.env`, never as a literal in the
/// tree. The publishable key is meant to be shipped in a client, but it still
/// names one project, and a key in git is a key that outlives the day someone
/// rotates it. `.env.example` is the committed template; `.env` is ignored.
///
/// ```
/// flutter run --dart-define-from-file=.env
/// ```
///
/// The file is read by the compiler, not at runtime, so it must be passed to
/// every command that builds the app. A build made without it is a build with
/// no account server, which [isConfigured] reports.
abstract final class SupabaseConfig {
  static const url = String.fromEnvironment('SUPABASE_URL');

  /// The client-side key. It is what Supabase now calls the publishable key;
  /// the anon key is the same value under its old name.
  static const publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );

  /// Where the confirmation and reset mails send the reader back to.
  ///
  /// A custom scheme, not an `https` address, because the mail is opened by a
  /// browser and only the scheme tells the phone that this app owns the link.
  /// It is declared three times and the three must stay equal: here, in the
  /// Android manifest `intent-filter`, and in the iOS `CFBundleURLSchemes`. A
  /// value that is in one and not the others opens the browser and stops
  /// there, which looks exactly like a mail that was never sent.
  ///
  /// Supabase refuses any `redirect_to` that is not in the project's
  /// **Redirect URLs** allow list, and falls back to the Site URL without
  /// saying so. Add `capyenergy://auth-callback` there before you build.
  static const redirectUrl = 'capyenergy://auth-callback';

  /// Whether this build can talk to a project at all.
  ///
  /// A build with no project is not a broken build: the archive and viewing
  /// still run without an account. Pairing requires a project and a
  /// signed-in account (device-flow via `device-pairing/claim`); there is no
  /// local-network fallback. A no-project build surfaces pairing as
  /// signed-out and the login step is skipped rather than showing a form
  /// that every press would refuse.
  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;
}
