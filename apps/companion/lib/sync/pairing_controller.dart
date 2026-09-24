import 'package:flutter/foundation.dart';
import 'package:telemetry_core/backend_reachability.dart';

import '../pairing/device_pairing_gateway.dart';
import 'pairing_restore.dart';
import 'pairing_store.dart';

/// Why the last pairing attempt failed. The screen maps this to copy.
///
/// Legacy values [rejected] and [carMissing] remain for compatibility with
/// the current onboarding screen, which switches on them. New distinct
/// outcomes are exposed via [lastResult] and [signedOut] without breaking
/// that switch.
enum PairingError { invalidCode, rejected, carMissing }

/// Owns the pairing form. The screen only draws it.
class PairingController extends ChangeNotifier {
  PairingController({
    required this.store,
    this.gateway,
    this.isSignedIn,
    this.reachabilityChecker,
    this.restoreLookup,
  });
  final PairingStore store;
  final DevicePairingGateway? gateway;

  /// Optional signed-in check. When provided and returns false, [submit]
  /// sets [signedOut] rather than calling the gateway. This makes the
  /// signed-out state distinct without a crash or silent no-op.
  final bool Function()? isSignedIn;

  /// Optional connectivity gate. When provided, [submit] probes it before
  /// touching the gateway. Injected (not hardcoded) so tests can fake it the
  /// same way [gateway] is faked. Production wiring belongs in
  /// [CompanionRuntime] via `BackendReachabilityChecker(client:
  /// HttpReachabilityClient(), backendUri: Uri.parse(SupabaseConfig.url))`.
  final BackendReachabilityChecker? reachabilityChecker;

  /// The cloud lookup that names this account's car. Injected like [gateway]
  /// so tests fake it; production reads the `vehicle` rows the account owns.
  /// Null means no restore path (no project, signed out, unconfigured
  /// build) and [restore] is a no-op.
  final Future<RestoredPairing?> Function()? restoreLookup;

  bool busy = false;
  PairingError? error;

  /// The full distinct outcome of the last gateway call, or null before the
  /// first claim. The next-wave screen reads this to tell each case apart
  /// instead of folding them into [error].
  ClaimResult? lastResult;

  /// True when the last [submit] was refused because no account was signed in.
  /// Distinct from [error] and [lastResult] so the caller can show the
  /// dedicated signed-out message.
  bool signedOut = false;

  /// The outcome of the last connectivity probe, or null before the first
  /// check. Distinct from [error]/[lastResult]/[signedOut] so the caller can
  /// tell "no network" and "backend not answering" apart from claim failures.
  /// Mirrors [BackendReachability] with a null "not yet checked" state.
  BackendReachability? connectivity;

  bool get isPaired => store.isPaired;

  /// Six digits from the car screen. The car need not be on any local
  /// network: the gateway claims the code through the cloud account.
  Future<void> submit(String rawCode) async {
    if (busy) return;
    final code = rawCode.replaceAll(RegExp(r'\D'), '');
    if (code.length != 6) {
      error = PairingError.invalidCode;
      lastResult = null;
      signedOut = false;
      notifyListeners();
      return;
    }

    // Signed-out is a distinct state, not a silent no-op.
    if (isSignedIn != null && !isSignedIn!()) {
      signedOut = true;
      error = null;
      lastResult = null;
      busy = false;
      notifyListeners();
      return;
    }

    // Connectivity gate: check before touching the gateway.
    final checker = reachabilityChecker;
    if (checker != null) {
      final reachability = await checker.check();
      connectivity = reachability;
      if (reachability != BackendReachability.reachable) {
        notifyListeners();
        return;
      }
      // Reachable: fall through to the busy/claim flow. Connectivity already
      // set so the screen can show "online, claiming…".
      // Fix race: two rapid taps both awaited checker before busy=true
      // and would both reach claim. Guard here after the async gap.
      if (busy) return;
    }

    busy = true;
    error = null;
    lastResult = null;
    signedOut = false;
    notifyListeners();
    // No-project build without a gateway: pairing requires a project and a
    // signed-in account. isSignedIn already surfaces signed-out for the
    // common case; this null-gateway branch is the fallback if isSignedIn is
    // absent or reports signed-in but no project is configured.
    final claimGateway = gateway;
    if (claimGateway == null) {
      lastResult = const ClaimResult.unknown();
      error = PairingError.rejected;
      busy = false;
      notifyListeners();
      return;
    }
    try {
      final result = await claimGateway.claim(code);
      lastResult = result;
      switch (result) {
        case ClaimSuccessResult(:final data):
          await store.completeClaim(
            vehicleId: data.vehicleId,
            accountId: data.accountId,
          );
          error = null;
          signedOut = false;
        case ClaimAlreadyOwnedBySelf():
          // Idempotent success: the car is already this account's. After a
          // reinstall the local store is empty, so run the same cloud
          // restore instead of keeping an empty store.
          if (!store.isPaired) await _doRestore(fromSubmit: true);
          error = null;
          signedOut = false;
        case ClaimNotFound():
          error = PairingError.rejected;
        case ClaimExpired():
          error = PairingError.rejected;
        case ClaimAlreadyClaimed():
          error = PairingError.rejected;
        case ClaimVehicleAlreadyClaimed():
          error = PairingError.rejected;
        case ClaimNetwork():
          error = PairingError.carMissing;
        case ClaimUnknown():
          error = PairingError.rejected;
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void>? _activeRestore;

  /// Restores this account's car link after a reinstall wiped the local file.
  ///
  /// No-op when already paired or when no restore path is wired. Never
  /// throws: offline or a failed lookup keeps today's behavior (show
  /// pairing) and a later start retries.
  Future<void> restore() {
    final active = _activeRestore;
    if (active != null) return active;
    if (store.isPaired || busy) return Future.value();
    final future = _doRestore();
    _activeRestore = future;
    return future.whenComplete(() {
      _activeRestore = null;
    });
  }

  Future<void> _doRestore({bool fromSubmit = false}) async {
    if (store.isPaired) return;
    if (!fromSubmit && busy) return;
    final lookup = restoreLookup;
    if (lookup == null) return;
    RestoredPairing? found;
    try {
      found = await lookup();
    } catch (_) {
      return;
    }
    if (store.isPaired) return;
    if (!fromSubmit && busy) return;
    final car = found;
    if (car == null) return;
    await store.completeClaim(
      vehicleId: car.vehicleId,
      accountId: car.accountId,
    );
    notifyListeners();
  }

  Future<void> unpair() async {
    await store.clear();
    error = null;
    lastResult = null;
    signedOut = false;
    connectivity = null;
    notifyListeners();
  }
}
