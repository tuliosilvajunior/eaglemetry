import 'package:capy_companion/pairing/device_pairing_gateway.dart';
import 'package:capy_companion/pairing/supabase_device_pairing_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/fake_device_pairing_gateway.dart';

void main() {
  group('FakeDevicePairingGateway', () {
    test('returns the configured result', () async {
      final gateway = FakeDevicePairingGateway(
        claimResult: const ClaimResult.notFound(),
      );

      final result = await gateway.claim('123-456');

      expect(result, isA<ClaimNotFound>());
      expect(gateway.claimCount, 1);
      expect(gateway.lastUserCode, '123-456');
    });

    test('defaults to success', () async {
      final gateway = FakeDevicePairingGateway();

      final result = await gateway.claim('000-000');

      expect(result, isA<ClaimSuccessResult>());
    });
  });

  group('SupabaseDevicePairingGateway.mapFunctionError', () {
    test('not_found (invalid_code) maps to ClaimNotFound', () {
      final error = FunctionsHttpException(
        status: 404,
        details: {
          'error': 'not_found',
          'reason': 'invalid_code',
          'message': 'Invalid user code',
        },
      );

      final result = SupabaseDevicePairingGateway.mapFunctionError(error);

      expect(result, isA<ClaimNotFound>());
    });

    test('expired maps to ClaimExpired', () {
      final error = FunctionsHttpException(
        status: 410,
        details: {
          'error': 'expired',
          'reason': 'expired',
          'message': 'Pairing code expired',
        },
      );

      final result = SupabaseDevicePairingGateway.mapFunctionError(error);

      expect(result, isA<ClaimExpired>());
    });

    test('already_claimed maps to ClaimAlreadyClaimed', () {
      final error = FunctionsHttpException(
        status: 409,
        details: {
          'error': 'already_claimed',
          'reason': 'already_claimed',
          'message': 'Pairing code already used',
        },
      );

      final result = SupabaseDevicePairingGateway.mapFunctionError(error);

      expect(result, isA<ClaimAlreadyClaimed>());
    });

    test('vehicle_already_claimed maps to ClaimVehicleAlreadyClaimed', () {
      final error = FunctionsHttpException(
        status: 409,
        details: {
          'error': 'vehicle_already_claimed',
          'reason': 'vehicle_already_claimed',
          'message': 'Vehicle already linked to another account',
        },
      );

      final result = SupabaseDevicePairingGateway.mapFunctionError(error);

      expect(result, isA<ClaimVehicleAlreadyClaimed>());
    });

    test('already_owned_by_self maps to ClaimAlreadyOwnedBySelf', () {
      final error = FunctionsHttpException(
        status: 200,
        details: {
          'error': 'already_owned_by_self',
          'reason': 'already_owned_by_self',
          'message': 'Vehicle already owned by this account',
        },
      );

      final result = SupabaseDevicePairingGateway.mapFunctionError(error);

      expect(result, isA<ClaimAlreadyOwnedBySelf>());
    });

    test('network fetch failure maps to ClaimNetwork', () {
      final error = FunctionsFetchException(
        details: Exception('Connection refused'),
      );

      final result = SupabaseDevicePairingGateway.mapFunctionError(error);

      expect(result, isA<ClaimNetwork>());
    });

    test('unknown reason maps to ClaimUnknown', () {
      final error = FunctionsHttpException(
        status: 500,
        details: {
          'error': 'server_error',
          'reason': 'insert_failed',
          'message': 'Failed to create pairing session',
        },
      );

      final result = SupabaseDevicePairingGateway.mapFunctionError(error);

      expect(result, isA<ClaimUnknown>());
    });

    test('fallback by status 404 without reason', () {
      final error = FunctionsHttpException(
        status: 404,
        details: <String, Object?>{},
      );

      final result = SupabaseDevicePairingGateway.mapFunctionError(error);

      expect(result, isA<ClaimNotFound>());
    });

    test('fallback by status 409 without reason', () {
      final error = FunctionsHttpException(
        status: 409,
        details: <String, Object?>{},
      );

      final result = SupabaseDevicePairingGateway.mapFunctionError(error);

      expect(result, isA<ClaimAlreadyClaimed>());
    });

    test('fallback by status 410 without reason', () {
      final error = FunctionsHttpException(
        status: 410,
        details: <String, Object?>{},
      );

      final result = SupabaseDevicePairingGateway.mapFunctionError(error);

      expect(result, isA<ClaimExpired>());
    });

    test('non-Map details maps to unknown', () {
      final error = FunctionsHttpException(
        status: 500,
        details: 'unexpected body',
      );

      final result = SupabaseDevicePairingGateway.mapFunctionError(error);

      expect(result, isA<ClaimUnknown>());
    });
  });

  group('ClaimResult sealed class', () {
    test('success carries vehicle and account ids', () {
      const result = ClaimResult.success(
        ClaimSuccess(vehicleId: 'v-123', accountId: 'a-456'),
      );

      expect(result, isA<ClaimSuccessResult>());
      final success = result as ClaimSuccessResult;
      expect(success.data.vehicleId, 'v-123');
      expect(success.data.accountId, 'a-456');
    });

    test('toString works for all variants', () {
      expect(const ClaimResult.notFound().toString(), contains('notFound'));
      expect(const ClaimResult.expired().toString(), contains('expired'));
      expect(
        const ClaimResult.alreadyClaimed().toString(),
        contains('alreadyClaimed'),
      );
      expect(
        const ClaimResult.alreadyOwnedBySelf().toString(),
        contains('alreadyOwnedBySelf'),
      );
      expect(
        const ClaimResult.vehicleAlreadyClaimed().toString(),
        contains('vehicleAlreadyClaimed'),
      );
      expect(const ClaimResult.network().toString(), contains('network'));
      expect(const ClaimResult.unknown().toString(), contains('unknown'));
    });
  });
}
