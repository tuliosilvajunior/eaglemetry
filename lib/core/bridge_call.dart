import 'package:flutter/services.dart';

/// Outcome of one platform-channel call.
///
/// Screens repeat the same `on PlatformException` / `catch` pair around every
/// bridge call; this collapses it into one `switch` so the failure message is
/// formatted in a single place and success can never be confused with a null
/// result.
sealed class BridgeCall<T> {
  const BridgeCall();
}

final class BridgeOk<T> extends BridgeCall<T> {
  const BridgeOk(this.value);

  final T value;
}

final class BridgeFailure<T> extends BridgeCall<T> {
  const BridgeFailure(this.message);

  /// Display-ready message: `code: message` for bridge errors, otherwise the
  /// raw error string.
  final String message;
}

/// Runs [body] and converts any failure into [BridgeFailure].
///
/// Errors are surfaced, never swallowed: callers are expected to render
/// [BridgeFailure.message] instead of silently keeping optimistic state.
Future<BridgeCall<T>> callBridge<T>(Future<T> Function() body) async {
  try {
    return BridgeOk(await body());
  } on PlatformException catch (error) {
    return BridgeFailure('${error.code}: ${error.message ?? 'bridge error'}');
  } catch (error) {
    return BridgeFailure(error.toString());
  }
}
