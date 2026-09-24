/// A successful claim response from the pairing server.
///
/// Carries the data a caller needs to proceed: the vehicle and the account that
/// now own it. Nothing else leaks from the server.
class ClaimSuccess {
  const ClaimSuccess({required this.vehicleId, required this.accountId});

  final String vehicleId;
  final String accountId;

  @override
  String toString() =>
      'ClaimSuccess(vehicleId: $vehicleId, accountId: $accountId)';
}

/// The distinguishable outcomes of a [DevicePairingGateway.claim] call.
///
/// Each case maps to a different user-facing message and a different next step.
/// They are deliberately not folded into a single error: an expired code asks
/// the reader to start over, while a vehicle already claimed by another account
/// asks them to contact the other owner.
sealed class ClaimResult {
  const ClaimResult._();

  const factory ClaimResult.success(ClaimSuccess data) = ClaimSuccessResult;
  const factory ClaimResult.notFound() = ClaimNotFound;
  const factory ClaimResult.expired() = ClaimExpired;
  const factory ClaimResult.alreadyClaimed() = ClaimAlreadyClaimed;
  const factory ClaimResult.alreadyOwnedBySelf() = ClaimAlreadyOwnedBySelf;
  const factory ClaimResult.vehicleAlreadyClaimed() =
      ClaimVehicleAlreadyClaimed;
  const factory ClaimResult.network() = ClaimNetwork;
  const factory ClaimResult.unknown() = ClaimUnknown;
}

/// The claim succeeded; the vehicle is now linked to the signed-in account.
final class ClaimSuccessResult extends ClaimResult {
  const ClaimSuccessResult(this.data) : super._();

  final ClaimSuccess data;

  @override
  String toString() => 'ClaimResult.success($data)';
}

/// No session matched the user code entered.
final class ClaimNotFound extends ClaimResult {
  const ClaimNotFound() : super._();

  @override
  String toString() => 'ClaimResult.notFound';
}

/// The pairing session expired before it was claimed.
final class ClaimExpired extends ClaimResult {
  const ClaimExpired() : super._();

  @override
  String toString() => 'ClaimResult.expired';
}

/// The pairing code was already used by another claim.
final class ClaimAlreadyClaimed extends ClaimResult {
  const ClaimAlreadyClaimed() : super._();

  @override
  String toString() => 'ClaimResult.alreadyClaimed';
}

/// The vehicle is already linked to the same account (idempotent success).
final class ClaimAlreadyOwnedBySelf extends ClaimResult {
  const ClaimAlreadyOwnedBySelf() : super._();

  @override
  String toString() => 'ClaimResult.alreadyOwnedBySelf';
}

/// The vehicle is already linked to a different account.
final class ClaimVehicleAlreadyClaimed extends ClaimResult {
  const ClaimVehicleAlreadyClaimed() : super._();

  @override
  String toString() => 'ClaimResult.vehicleAlreadyClaimed';
}

/// The network or server could not be reached.
final class ClaimNetwork extends ClaimResult {
  const ClaimNetwork() : super._();

  @override
  String toString() => 'ClaimResult.network';
}

/// An unexpected failure occurred.
final class ClaimUnknown extends ClaimResult {
  const ClaimUnknown() : super._();

  @override
  String toString() => 'ClaimResult.unknown';
}

/// The pairing actions the companion app needs.
///
/// A single method: enter a user code displayed on the car's head unit and
/// link the vehicle to the signed-in account. The provider stays behind this
/// interface so a change of backend is a change of one file, not of every
/// screen.
abstract interface class DevicePairingGateway {
  /// Claims the vehicle whose pairing code matches [userCode].
  ///
  /// The code is accepted as 6 digits, with or without the dash (e.g.
  /// `482910` or `482-910`). The server normalizes both forms.
  Future<ClaimResult> claim(String userCode);
}
