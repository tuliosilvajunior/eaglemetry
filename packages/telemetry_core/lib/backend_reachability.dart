import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The three distinguishable answers a reachability probe can give.
///
/// Each case maps to a different user-facing state and a different next step.
/// They are deliberately not folded into a single error: a device with no
/// network has a different fix (turn on Wi-Fi / hotspot) than a device on a
/// network that cannot reach the backend (captive portal, DNS, firewall).
///
/// Mirrors the `CloudSink` / `DevicePairingGateway` split: the network is
/// behind a seam so tests drive every outcome without real I/O.
enum BackendReachability {
  /// The device has no usable network connection.
  noNetwork,

  /// The device is on a network, but a request to the backend did not
  /// succeed. Includes timeouts, DNS failures, non-2xx status codes, and
  /// captive-portal interception (200 with an HTML login page).
  backendUnreachable,

  /// The backend answered with a valid response.
  reachable,
}

/// The response a [ReachabilityClient] returns when the HTTP round trip
/// completes.
///
/// The checker inspects [statusCode], [headers] and [body] to distinguish a
/// real backend answer from a captive-portal page that also returned 200.
class ReachabilityResponse {
  const ReachabilityResponse({
    required this.statusCode,
    this.headers = const {},
    this.body = '',
  });

  final int statusCode;
  final Map<String, String> headers;
  final String body;
}

/// Seam for the network call. Production uses [HttpReachabilityClient]; tests
/// inject a fake that returns or throws on demand.
///
/// This is the same pluggability already used by [CloudSink] and
/// [DevicePairingGateway]: one interface, a real HTTP implementation, and a
/// fake for tests. The seam lets unit tests cover all three
/// [BackendReachability] outcomes plus the timeout without real networking.
abstract interface class ReachabilityClient {
  /// Performs a `GET` against [uri] and returns the response. An implementation
  /// must honour [timeout] or the checker will enforce it with
  /// `Future.timeout`.
  Future<ReachabilityResponse> get(
    Uri uri, {
    required Duration timeout,
    Map<String, String>? headers,
  });
}

/// Production [ReachabilityClient] over `dart:io` [HttpClient].
///
/// Uses the platform HTTP stack — no heavyweight `http`/`dio` dependency. The
/// same constraint already applies to `HttpCloudSink` and
/// `HttpDevicePairingClient` on the car side.
class HttpReachabilityClient implements ReachabilityClient {
  HttpReachabilityClient({HttpClient? httpClient})
    : _client = httpClient ?? HttpClient();

  final HttpClient _client;

  @override
  Future<ReachabilityResponse> get(
    Uri uri, {
    required Duration timeout,
    Map<String, String>? headers,
  }) async {
    final request = await _client.getUrl(uri);
    request.followRedirects = true;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (headers != null) {
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
    }
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    final headersMap = <String, String>{};
    response.headers.forEach((name, values) {
      headersMap[name.toLowerCase()] = values.join(', ');
    });
    return ReachabilityResponse(
      statusCode: response.statusCode,
      headers: headersMap,
      body: body,
    );
  }
}

/// Answers whether this device can actually reach the backend right now.
///
/// Must involve a real round trip — a platform "is on Wi-Fi?" flag is not
class BackendReachabilityChecker {
  BackendReachabilityChecker({
    required this.client,
    required this.backendUri,
    this.timeout = const Duration(seconds: 3),
    this.validateResponse,
    this.headers,
  });

  /// The HTTP seam. Injected so tests can drive every outcome.
  final ReachabilityClient client;

  /// The backend endpoint to probe. Callers pass the Supabase base URL
  /// (car: `BuildConfig.SUPABASE_URL`; companion: `SupabaseConfig.url`).
  ///
  /// A lightweight `GET` is enough; the checker only cares that the backend
  /// answered and that the answer is not a captive-portal HTML page.
  final Uri backendUri;

  /// How long to wait before the backend is considered unreachable. Explicit
  /// and short by design — the pairing screen is waiting.
  final Duration timeout;

  /// Optional extra validation. When `null`, the default rule applies:
  /// 2xx is reachable unless the body/headers look like a captive-portal HTML
  /// page. Callers may supply a stricter predicate (e.g. check a JSON shape).
  final bool Function(ReachabilityResponse response)? validateResponse;

  /// Optional extra request headers (e.g. `apikey` for Supabase health probe).
  final Map<String, String>? headers;

  /// Performs one probe and returns the outcome. Never throws.
  Future<BackendReachability> check() async {
    try {
      final response = await client
          .get(backendUri, timeout: timeout, headers: headers)
          .timeout(timeout);
      if (!_isSuccessResponse(response)) {
        return BackendReachability.backendUnreachable;
      }
      return BackendReachability.reachable;
    } on SocketException catch (e) {
      if (_isNoNetwork(e)) {
        return BackendReachability.noNetwork;
      }
      return BackendReachability.backendUnreachable;
    } on TimeoutException {
      return BackendReachability.backendUnreachable;
    } catch (_) {
      return BackendReachability.backendUnreachable;
    }
  }

  /// True only for OS errors that mean the device has no usable interface.
  ///
  /// DNS lookup failures (EAI_NONAME / 8), connection-refused (61),
  /// connection-reset (54), and ETIMEDOUT (60/110) are all [SocketException]s
  /// in `dart:io` but they already had a network and failed to reach the
  /// backend — they must be `backendUnreachable`, not `noNetwork`. Only
  /// ENETDOWN/ENETUNREACH/EHOSTUNREACH family codes are genuine no-network.
  static bool _isNoNetwork(SocketException e) {
    final code = e.osError?.errorCode;
    if (code == null) return false;
    // Linux (Android): ENETDOWN 100, ENETUNREACH 101, EHOSTUNREACH 113.
    // Darwin/BSD (macOS/iOS): ENETDOWN 50, ENETUNREACH 51, EHOSTUNREACH 65.
    const noNetworkCodes = {100, 101, 113, 50, 51, 65};
    return noNetworkCodes.contains(code);
  }

  bool _isSuccessResponse(ReachabilityResponse response) {
    if (validateResponse != null) {
      return validateResponse!(response);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return false;
    }
    final contentType = (response.headers['content-type'] ?? '').toLowerCase();
    if (contentType.contains('text/html')) {
      return false;
    }
    if (_looksLikeHtml(response.body)) {
      return false;
    }
    return true;
  }

  static bool _looksLikeHtml(String body) {
    final trimmed = body.trimLeft().toLowerCase();
    if (trimmed.isEmpty) return false;
    // Captive portals answer 200 with HTML but may use text/plain, no
    // content-type, or a body starting with <head>/<meta>/<!-- rather than
    // just <!doctype html>/<html>. Anything starting with '<' is not a
    // backend JSON API answer; treat it as a portal.
    if (trimmed.startsWith('<!doctype')) return true;
    if (trimmed.startsWith('<html')) return true;
    if (trimmed.startsWith('<head')) return true;
    if (trimmed.startsWith('<body')) return true;
    if (trimmed.startsWith('<meta')) return true;
    if (trimmed.startsWith('<!--')) return true;
    if (trimmed.startsWith('<')) return true;
    return false;
  }
}
