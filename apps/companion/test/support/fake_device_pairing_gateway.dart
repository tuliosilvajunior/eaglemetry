import 'package:capy_companion/pairing/device_pairing_gateway.dart';

/// A pairing server that answers from a map, so a test needs no network.
class FakeDevicePairingGateway implements DevicePairingGateway {
  FakeDevicePairingGateway({
    this.claimResult = const ClaimResult.success(
      ClaimSuccess(vehicleId: 'v1', accountId: 'a1'),
    ),
  });

  /// The result the next [claim] call will return.
  ClaimResult claimResult;

  /// How many times [claim] was called.
  int claimCount = 0;

  /// The last user code passed to [claim].
  String? lastUserCode;

  @override
  Future<ClaimResult> claim(String userCode) async {
    claimCount++;
    lastUserCode = userCode;
    return claimResult;
  }
}
