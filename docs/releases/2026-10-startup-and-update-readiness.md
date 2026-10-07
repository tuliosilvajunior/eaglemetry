# Startup validation and internet update readiness

## Validation on 2026-10-07

The vehicle had a Flutter debug/JIT APK. Reopening the Activity took about six
seconds. A release/AOT build from the same working tree reduced the median
Android `am start -W` TotalTime from 5,904 ms to 285 ms (five runs per mode).
The process stayed alive during each series. The first Activity launch after
installation took 534 ms; this is not a full vehicle cold-boot measurement.

The release used application ID `com.timhss.capy`, version code 715 and database
schema 48. Its signing certificate matched the previous APK. All existing
session IDs, interval keys and event IDs survived installation. Pairing remained
approved with the same credentials. Collection continued. FORCE SYNC cleared the
ended-session dirty flags, and a read from Supabase confirmed all six ended
session IDs. The active session still had pending records, as expected.

The local build name `0.1.2-debug` is the install script's auto-update opt-out
marker. It is a Flutter **release** build. Do not infer compilation mode from that
suffix. Use `scripts/install.sh` for vehicle installs. The cloud configuration
helper must also produce release/AOT, not the debug/JIT APK used in the slow test.

## Two update controls

**App updates** installs the Eaglemetry APK. `AppUpdateManager` reads
`BuildConfig.APP_UPDATE_MANIFEST_URL`, checks the version code, package and
signature, then schedules installation. The installed local test build has no
app update URL and carries the local opt-out marker. It will not move to a
published channel on its own.

**Roadcast** updates the native telemetry daemon. `RoadcastUpdateManager` uses
the upstream `Timoteohss/roadcast` edge release manifest and daemon asset. This
is a separate channel from the Eaglemetry APK. The app update path also calls
Roadcast update preparation before installing an app update, so compatibility
between the two matters. No Roadcast binary was changed in this work.

## Before enabling Eaglemetry internet releases

The checked-in release workflow now targets `tuliosilvajunior/eaglemetry-releases`.
Do not treat a source push or PR merge as proof that the vehicle update channel
is ready until the secrets and one real release are verified.

1. Verify that `tuliosilvajunior/eaglemetry-releases` is public and can receive
   releases from the source workflow.
2. The app now defaults to the `latest.json` asset in that repository. Preserve
   the native Supabase URL, anon/publishable key and functions URL, with cloud
   sync enabled.
3. Verify signing, publication and Supabase build secrets in GitHub Actions.
   The release workflow requires `PLATFORM_KEYSTORE_BASE64`,
   `PUBLIC_RELEASE_TOKEN`, `SUPABASE_URL`, `SUPABASE_ANON_KEY` and
   `SUPABASE_FUNCTIONS_URL`; their values are injected only during the CI
   build and are not committed to the repository.
4. Keep Android version codes monotonic. The car already has 715. The workflow
   derives the next code from Git commit count with a 715 baseline, so the
   first public release is above the installed build even though this imported
   repository has much less history than the original source repository.
5. Build the public channel without the local `-debug` version-name marker.
   Keep Flutter release mode, the same signing identity and a compatible schema.
6. Validate APK and manifest as draft assets before publishing them to the
   live channel. Check checksum, size, package, version, signing certificate and
   Roadcast compatibility. Confirm that the actual daemon assets can be fetched.
7. Take a database snapshot and install one channel-enabled release onto the
   local test car with the project install procedure adapted explicitly for a
   public-channel build. The ordinary install script adds the local marker, so
   it cannot by itself enable OTA. Do not remove the marker from a test build
   until the channel is ready. Keep data and pairing, then test the two settings
   controls independently and test one subsequent update over the internet.

The current source synchronization does not publish an APK or change the live
Roadcast channel. The HTTP lazy-initialization proposal from the investigation
was not needed for the measured startup improvement and is not included.
