/// Cloud-sync gate for Lanes A/B/C.
///
/// Every prior phase shipped with the production `CloudSink` as a no-op
/// (`NoopCloudSink` inert, `SupabaseCloudSink.uploaderFor` returning null when
/// `SupabaseConfig` is not configured, zero call sites for
/// `AnnotationCloudSync`). Standing decision from the owner: the cloud stays
/// on. The gate defaults to `true`, so a build that carries a project syncs
/// without an extra define; an explicit `--dart-define=CLOUD_SYNC_ENABLED=false`
/// still turns it off for a build that needs it.
///
/// Sourcing follows the already-established pattern: the companion's Supabase
/// credentials arrive via `String.fromEnvironment('SUPABASE_URL')` and
/// `'SUPABASE_PUBLISHABLE_KEY'` from `--dart-define-from-file=.env`
/// (`SupabaseConfig`). The gate itself is a separate dart-define that
/// defaults to `true`, so a build without Supabase credentials still behaves
/// exactly as before (no-op) — syncing needs both the gate and a project.
///
/// Production builds therefore sync with the cloud whenever the project is
/// configured, matching the car's `BuildConfig.CLOUD_SYNC_ENABLED` gate.
///
/// Usage:
/// ```dart
/// flutter run --dart-define-from-file=.env
/// ```
abstract final class CloudSyncConfig {
  /// Whether real cloud sinks may be resolved.
  ///
  /// `true` by default — production syncs whenever `SupabaseConfig.isConfigured`
  /// is also true. An explicit `false` define restores the old inert behavior.
  static const enabled = bool.fromEnvironment(
    'CLOUD_SYNC_ENABLED',
    defaultValue: true,
  );
}
