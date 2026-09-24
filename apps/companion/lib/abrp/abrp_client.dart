import 'dart:convert';
import 'dart:io';
import 'package:telemetry_core/telemetry_core.dart';
import 'abrp_payload.dart';

class AbrpSendResult {
  final bool isSuccess;
  final int statusCode;
  final String? errorMessage;
  final dynamic result;

  const AbrpSendResult({
    required this.isSuccess,
    required this.statusCode,
    this.errorMessage,
    this.result,
  });
}

/// HTTP client for transmitting live telemetry to the Iternio ABRP Telemetry API.
class AbrpClient {
  /// Reported when no key is configured, in place of a request that could only
  /// come back as `401 Unauthorized Key`.
  static const String missingApiKeyError = 'ABRP API key not configured';

  final String baseUrl;
  final String apiKey;
  final HttpClient _httpClient;

  static const String defaultApiUrl = 'https://api.iternio.com/1/tlm/send';

  /// Ships empty. The app carries no Iternio key of its own: Iternio
  /// rate-limits per key, so one key shared by every install would throttle
  /// everybody. Each user brings their own, and [sendTelemetry] refuses to
  /// call without one.
  AbrpClient({
    this.baseUrl = defaultApiUrl,
    this.apiKey = '',
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient();

  /// Transmits a [LiveTelemetrySnapshot] to ABRP for the given user [token].
  ///
  /// [apiKeyOverride] is the user's own key, and it wins over [apiKey]. With
  /// neither, the call is refused here rather than sent: the server would
  /// answer `401 Unauthorized Key`, and a refusal names the missing setting.
  Future<AbrpSendResult> sendTelemetry({
    required String userToken,
    required LiveTelemetrySnapshot snapshot,
    String? carModel,
    String? apiKeyOverride,
  }) async {
    final effectiveKey = (apiKeyOverride != null && apiKeyOverride.isNotBlank)
        ? apiKeyOverride.trim()
        : apiKey.trim();
    if (effectiveKey.isEmpty) {
      return const AbrpSendResult(
        isSuccess: false,
        statusCode: 0,
        errorMessage: missingApiKeyError,
      );
    }
    try {
      final uri = Uri.parse(baseUrl).replace(
        queryParameters: {'api_key': effectiveKey, 'token': userToken.trim()},
      );

      final payload = <String, dynamic>{'tlm': AbrpPayload.from(snapshot)};
      if (carModel != null && carModel.isNotBlank) {
        payload['car_model'] = carModel;
      }

      final request = await _httpClient.postUrl(uri);
      request.headers.set('Authorization', 'APIKEY $effectiveKey');
      request.headers.contentType = ContentType.json;
      final bodyBytes = utf8.encode(jsonEncode(payload));
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      final response = await request.close();
      final responseBody = await utf8.decodeStream(response);

      if (response.statusCode == HttpStatus.ok) {
        try {
          final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
          final status = decoded['status'] as String? ?? 'ok';
          if (status == 'ok') {
            return AbrpSendResult(
              isSuccess: true,
              statusCode: response.statusCode,
              result: decoded['result'],
            );
          } else {
            final errorMsg =
                decoded['message'] as String? ??
                decoded['error'] as String? ??
                'ABRP status: $status';
            return AbrpSendResult(
              isSuccess: false,
              statusCode: response.statusCode,
              errorMessage: errorMsg,
            );
          }
        } catch (_) {
          return AbrpSendResult(
            isSuccess: true,
            statusCode: response.statusCode,
          );
        }
      } else {
        String? errorMsg;
        try {
          final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
          errorMsg =
              decoded['message'] as String? ?? decoded['error'] as String?;
        } catch (_) {
          errorMsg = responseBody;
        }
        return AbrpSendResult(
          isSuccess: false,
          statusCode: response.statusCode,
          errorMessage: errorMsg ?? 'HTTP ${response.statusCode}',
        );
      }
    } catch (e) {
      return AbrpSendResult(
        isSuccess: false,
        statusCode: 0,
        errorMessage: e.toString(),
      );
    }
  }

  void close() {
    _httpClient.close(force: true);
  }
}

extension on String {
  bool get isNotBlank => trim().isNotEmpty;
}
