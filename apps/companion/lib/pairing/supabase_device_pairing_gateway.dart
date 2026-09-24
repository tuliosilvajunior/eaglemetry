import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/supabase_config.dart';
import 'device_pairing_gateway.dart';

/// The one file in the pairing layer that knows the cloud is Supabase.
///
/// Everything above it speaks [DevicePairingGateway] and [ClaimResult]. The
/// provider's own [FunctionException] never leaves this class, because its
/// details are server text: it is not localized, it changes between releases
/// of the service, and it must not reach a screen.
class SupabaseDevicePairingGateway implements DevicePairingGateway {
  SupabaseDevicePairingGateway(this._client);

  /// Answers the gateway when this build carries a project, or null otherwise.
  ///
  /// A build with no project cannot claim a vehicle: the pairing journey
  /// must not show a form that every press would refuse.
  static SupabaseDevicePairingGateway? get current {
    if (!SupabaseConfig.isConfigured) return null;
    return SupabaseDevicePairingGateway(Supabase.instance.client);
  }

  final SupabaseClient _client;

  @override
  Future<ClaimResult> claim(String userCode) =>
      _guard(() async => _claim(userCode));

  Future<ClaimResult> _claim(String userCode) async {
    final response = await _client.functions.invoke(
      'device-pairing/claim',
      body: {'user_code': userCode},
    );
    final data = response.data;
    if (data is Map<String, Object?> && data['status'] == 'approved') {
      final vehicleId = data['vehicle_id'] as String? ?? '';
      final accountId = data['account_id'] as String? ?? '';
      if (vehicleId.isEmpty || accountId.isEmpty) {
        return const ClaimResult.unknown();
      }
      return ClaimResult.success(
        ClaimSuccess(vehicleId: vehicleId, accountId: accountId),
      );
    }
    return const ClaimResult.unknown();
  }

  /// Turns every way the provider can fail into a [ClaimResult].
  Future<ClaimResult> _guard(Future<ClaimResult> Function() action) async {
    try {
      return await action();
    } on ClaimResult {
      rethrow;
    } on FunctionException catch (error) {
      return mapFunctionError(error);
    } on SocketException catch (_) {
      return const ClaimResult.network();
    } on TimeoutException catch (_) {
      return const ClaimResult.network();
    } on Object catch (_) {
      return const ClaimResult.unknown();
    }
  }

  /// Maps a provider error to a [ClaimResult].
  ///
  /// Visible for testing. Reads the server's `reason` field, not the message.
  static ClaimResult mapFunctionError(FunctionException error) {
    if (error is FunctionsFetchException) {
      return const ClaimResult.network();
    }
    final details = error.details;
    final reason = switch (details) {
      Map<String, Object?> m => m['reason'] as String?,
      _ => null,
    };
    if (reason != null) return _mapReason(reason);
    return _mapByStatus(error.status);
  }

  static ClaimResult _mapReason(String reason) {
    return switch (reason) {
      'invalid_code' => const ClaimResult.notFound(),
      'expired' => const ClaimResult.expired(),
      'already_claimed' => const ClaimResult.alreadyClaimed(),
      'already_owned_by_self' => const ClaimResult.alreadyOwnedBySelf(),
      'vehicle_already_claimed' => const ClaimResult.vehicleAlreadyClaimed(),
      _ => const ClaimResult.unknown(),
    };
  }

  /// Fallback when the server did not send a recognized reason.
  static ClaimResult _mapByStatus(int status) {
    return switch (status) {
      404 => const ClaimResult.notFound(),
      409 => const ClaimResult.alreadyClaimed(),
      410 => const ClaimResult.expired(),
      _ => const ClaimResult.unknown(),
    };
  }
}
