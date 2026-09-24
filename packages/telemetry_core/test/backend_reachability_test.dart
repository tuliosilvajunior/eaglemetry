import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/backend_reachability.dart';

class FakeReachabilityClient implements ReachabilityClient {
  FakeReachabilityClient({this.response, this.exception, this.delay});

  ReachabilityResponse? response;
  Object? exception;
  Duration? delay;
  int calls = 0;
  Uri? lastUri;
  Duration? lastTimeout;
  Map<String, String>? lastHeaders;

  @override
  Future<ReachabilityResponse> get(
    Uri uri, {
    required Duration timeout,
    Map<String, String>? headers,
  }) async {
    calls++;
    lastUri = uri;
    lastTimeout = timeout;
    lastHeaders = headers;
    if (delay != null) {
      await Future.delayed(delay!);
    }
    if (exception != null) {
      // Re-throw as async error so check() sees it.
      Error.throwWithStackTrace(exception!, StackTrace.current);
    }
    return response ??
        const ReachabilityResponse(statusCode: 200, body: '{"ok":true}');
  }
}

SocketException socketExceptionWithCode(int code, [String message = 'mock']) {
  return SocketException(message, osError: OSError('', code));
}

void main() {
  final backendUri = Uri.parse('https://example.supabase.co');

  group('BackendReachabilityChecker', () {
    test('returns reachable when backend answers 200', () async {
      final client = FakeReachabilityClient(
        response: const ReachabilityResponse(
          statusCode: 200,
          headers: {'content-type': 'application/json'},
          body: '{"status":"ok"}',
        ),
      );
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
      );
      expect(await checker.check(), BackendReachability.reachable);
    });

    test('returns reachable on 204 with empty body', () async {
      final client = FakeReachabilityClient(
        response: const ReachabilityResponse(statusCode: 204),
      );
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
      );
      expect(await checker.check(), BackendReachability.reachable);
    });

    test('returns noNetwork only for ENETUNREACH family codes', () async {
      // Linux: 100 ENETDOWN, 101 ENETUNREACH, 113 EHOSTUNREACH
      // Darwin: 50 ENETDOWN, 51 ENETUNREACH, 65 EHOSTUNREACH
      for (final code in [100, 101, 113, 50, 51, 65]) {
        final client = FakeReachabilityClient(
          exception: socketExceptionWithCode(code),
        );
        final checker = BackendReachabilityChecker(
          client: client,
          backendUri: backendUri,
        );
        expect(
          await checker.check(),
          BackendReachability.noNetwork,
          reason: 'osError $code must be noNetwork',
        );
      }
    });

    test(
      'returns backendUnreachable for DNS, refused, reset, timeout codes (SocketException)',
      () async {
        // 8 EAI_NONAME/DNS, 61 ECONNREFUSED, 54 ECONNRESET, 60/110 ETIMEDOUT
        // and generic SocketException without osError are all backendUnreachable,
        // not noNetwork - they already had a network and failed to reach backend.
        for (final code in [8, 61, 54, 60, 110]) {
          final client = FakeReachabilityClient(
            exception: socketExceptionWithCode(code),
          );
          final checker = BackendReachabilityChecker(
            client: client,
            backendUri: backendUri,
          );
          expect(
            await checker.check(),
            BackendReachability.backendUnreachable,
            reason: 'osError $code must be backendUnreachable, not noNetwork',
          );
        }
        // No osError at all is also backendUnreachable (conservative).
        final noOsErrorClient = FakeReachabilityClient(
          exception: const SocketException('Network is unreachable'),
        );
        final checker2 = BackendReachabilityChecker(
          client: noOsErrorClient,
          backendUri: backendUri,
        );
        expect(await checker2.check(), BackendReachability.backendUnreachable);

        final nullCodeClient = FakeReachabilityClient(
          exception: SocketException('fail', osError: OSError('', 9999)),
        );
        final checker3 = BackendReachabilityChecker(
          client: nullCodeClient,
          backendUri: backendUri,
        );
        expect(await checker3.check(), BackendReachability.backendUnreachable);
      },
    );

    test('returns backendUnreachable on non-2xx', () async {
      for (final code in [400, 401, 403, 404, 500, 502, 503]) {
        final client = FakeReachabilityClient(
          response: ReachabilityResponse(statusCode: code),
        );
        final checker = BackendReachabilityChecker(
          client: client,
          backendUri: backendUri,
        );
        expect(
          await checker.check(),
          BackendReachability.backendUnreachable,
          reason: 'status $code must be backendUnreachable',
        );
      }
    });

    test(
      'returns backendUnreachable on TimeoutException from client',
      () async {
        final client = FakeReachabilityClient(
          exception: TimeoutException('timed out', const Duration(seconds: 3)),
        );
        final checker = BackendReachabilityChecker(
          client: client,
          backendUri: backendUri,
        );
        expect(await checker.check(), BackendReachability.backendUnreachable);
      },
    );

    test('returns backendUnreachable on HttpException', () async {
      final client = FakeReachabilityClient(
        exception: const HttpException('Connection closed'),
      );
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
      );
      expect(await checker.check(), BackendReachability.backendUnreachable);
    });

    test('returns backendUnreachable on generic exception', () async {
      final client = FakeReachabilityClient(
        exception: FormatException('bad json'),
      );
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
      );
      expect(await checker.check(), BackendReachability.backendUnreachable);
    });

    test(
      'returns backendUnreachable on captive-portal HTML content-type',
      () async {
        final client = FakeReachabilityClient(
          response: const ReachabilityResponse(
            statusCode: 200,
            headers: {'content-type': 'text/html; charset=utf-8'},
            body: '<html><body>Login</body></html>',
          ),
        );
        final checker = BackendReachabilityChecker(
          client: client,
          backendUri: backendUri,
        );
        expect(await checker.check(), BackendReachability.backendUnreachable);
      },
    );

    test(
      'returns backendUnreachable on captive-portal HTML body with 200',
      () async {
        final client = FakeReachabilityClient(
          response: const ReachabilityResponse(
            statusCode: 200,
            headers: {'content-type': 'application/json'},
            body: '<!DOCTYPE html><html>portal</html>',
          ),
        );
        final checker = BackendReachabilityChecker(
          client: client,
          backendUri: backendUri,
        );
        expect(await checker.check(), BackendReachability.backendUnreachable);
      },
    );

    test('returns backendUnreachable on <html body without doctype', () async {
      final client = FakeReachabilityClient(
        response: const ReachabilityResponse(
          statusCode: 200,
          body: '   <html><head></head></html>',
        ),
      );
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
      );
      expect(await checker.check(), BackendReachability.backendUnreachable);
    });

    test('broadened portal sniff: detects <head>, <meta>, <!--, <body', () async {
      for (final body in [
        '<head><title>Portal</title></head>',
        '  <meta http-equiv="refresh" content="0; url=login">',
        '<!-- captive portal --> <html>',
        '<body>Login page</body>',
        '<!DOCTYPE html>',
        '<div>portal</div>', // generic html starting with <
        '<META charset="utf-8">',
      ]) {
        final client = FakeReachabilityClient(
          response: ReachabilityResponse(
            statusCode: 200,
            // text/plain or absent content-type must still be caught via body sniff
            headers: const {'content-type': 'text/plain'},
            body: body,
          ),
        );
        final checker = BackendReachabilityChecker(
          client: client,
          backendUri: backendUri,
        );
        expect(
          await checker.check(),
          BackendReachability.backendUnreachable,
          reason: 'body "$body" must be portal -> backendUnreachable',
        );
      }
    });

    test(
      'portal sniff: no content-type with html body is still portal',
      () async {
        final client = FakeReachabilityClient(
          response: const ReachabilityResponse(
            statusCode: 200,
            body: '<html>portal</html>',
          ),
        );
        final checker = BackendReachabilityChecker(
          client: client,
          backendUri: backendUri,
        );
        expect(await checker.check(), BackendReachability.backendUnreachable);
      },
    );

    test(
      'portal sniff: JSON containing html substring is still reachable',
      () async {
        // Real backend JSON that happens to contain a string with <head> inside
        // but is otherwise valid JSON starting with { must not be mis-flagged.
        final client = FakeReachabilityClient(
          response: const ReachabilityResponse(
            statusCode: 200,
            headers: {'content-type': 'application/json'},
            body: '{"msg":"hello <head>world"}',
          ),
        );
        final checker = BackendReachabilityChecker(
          client: client,
          backendUri: backendUri,
        );
        expect(await checker.check(), BackendReachability.reachable);
      },
    );

    test('timeout: returns backendUnreachable when client hangs', () async {
      final client = FakeReachabilityClient(
        delay: const Duration(milliseconds: 300),
        response: const ReachabilityResponse(statusCode: 200),
      );
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
        timeout: const Duration(milliseconds: 50),
      );
      final stopwatch = Stopwatch()..start();
      final result = await checker.check();
      stopwatch.stop();
      expect(result, BackendReachability.backendUnreachable);
      // Must be short - not hang for the full fake delay.
      expect(stopwatch.elapsedMilliseconds, lessThan(200));
    });

    test('has short explicit default timeout of 3 seconds', () {
      final client = FakeReachabilityClient();
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
      );
      expect(checker.timeout, const Duration(seconds: 3));
    });

    test('passes timeout to client', () async {
      final client = FakeReachabilityClient();
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
        timeout: const Duration(seconds: 2),
      );
      await checker.check();
      expect(client.lastTimeout, const Duration(seconds: 2));
    });

    test('passes backendUri to client', () async {
      final client = FakeReachabilityClient();
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
      );
      await checker.check();
      expect(client.lastUri, backendUri);
    });

    test('never throws, every failure is an outcome', () async {
      final throwingClients = [
        FakeReachabilityClient(exception: socketExceptionWithCode(101)),
        FakeReachabilityClient(exception: socketExceptionWithCode(61)),
        FakeReachabilityClient(exception: TimeoutException('t', Duration.zero)),
        FakeReachabilityClient(exception: const HttpException('x')),
        FakeReachabilityClient(exception: StateError('boom')),
        FakeReachabilityClient(exception: Exception('generic')),
      ];
      for (final client in throwingClients) {
        final checker = BackendReachabilityChecker(
          client: client,
          backendUri: backendUri,
        );
        // Must not throw.
        final result = await checker.check();
        expect(
          result,
          isIn([
            BackendReachability.noNetwork,
            BackendReachability.backendUnreachable,
            BackendReachability.reachable,
          ]),
        );
      }
    });

    test('does not cache: Retry genuinely re-checks', () async {
      final client = FakeReachabilityClient(
        response: const ReachabilityResponse(statusCode: 200),
      );
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
      );
      expect(await checker.check(), BackendReachability.reachable);

      // Change fake to simulate backend going down.
      client.response = const ReachabilityResponse(statusCode: 503);
      expect(await checker.check(), BackendReachability.backendUnreachable);

      // Change to no network (specific code).
      client.response = null;
      client.exception = socketExceptionWithCode(101);
      expect(await checker.check(), BackendReachability.noNetwork);
      expect(client.calls, 3);
    });

    test(
      'custom validateResponse overrides default portal detection',
      () async {
        // Default would treat 200 html as backendUnreachable.
        final htmlClient = FakeReachabilityClient(
          response: const ReachabilityResponse(
            statusCode: 200,
            headers: {'content-type': 'text/html'},
            body: '<html>portal</html>',
          ),
        );
        final defaultChecker = BackendReachabilityChecker(
          client: htmlClient,
          backendUri: backendUri,
        );
        expect(
          await defaultChecker.check(),
          BackendReachability.backendUnreachable,
        );

        // With custom validator that accepts any 200 regardless of body.
        final customChecker = BackendReachabilityChecker(
          client: htmlClient,
          backendUri: backendUri,
          validateResponse: (r) => r.statusCode == 200,
        );
        expect(await customChecker.check(), BackendReachability.reachable);
      },
    );

    test('custom validateResponse can reject even 200 json', () async {
      final client = FakeReachabilityClient(
        response: const ReachabilityResponse(
          statusCode: 200,
          body: '{"wrong":true}',
        ),
      );
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
        validateResponse: (r) => r.body.contains('"ok"'),
      );
      expect(await checker.check(), BackendReachability.backendUnreachable);
    });

    test('forwards headers to client when configured', () async {
      final client = FakeReachabilityClient();
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
        headers: const {'apikey': 'test-key-123'},
      );
      await checker.check();
      expect(client.lastHeaders, {'apikey': 'test-key-123'});
      expect(client.lastUri, backendUri);
    });

    test('sends null headers when none configured', () async {
      final client = FakeReachabilityClient();
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: backendUri,
      );
      await checker.check();
      expect(client.lastHeaders, isNull);
    });

    test('headers do not affect outcome classification', () async {
      // With apikey header, 200 is still reachable, 401 is backendUnreachable.
      final client200 = FakeReachabilityClient(
        response: const ReachabilityResponse(statusCode: 200, body: '{}'),
      );
      final checker200 = BackendReachabilityChecker(
        client: client200,
        backendUri: backendUri,
        headers: const {'apikey': 'k'},
      );
      expect(await checker200.check(), BackendReachability.reachable);

      final client401 = FakeReachabilityClient(
        response: const ReachabilityResponse(statusCode: 401),
      );
      final checker401 = BackendReachabilityChecker(
        client: client401,
        backendUri: backendUri,
        headers: const {'apikey': 'k'},
      );
      expect(await checker401.check(), BackendReachability.backendUnreachable);
    });

    test('HttpReachabilityClient sends apikey header to real server', () async {
      // Real HttpServer test for headers plumbing.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? capturedApikey;
      server.listen((req) async {
        capturedApikey = req.headers.value('apikey');
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"ok":true}');
        await req.response.close();
      });
      final client = HttpReachabilityClient();
      final uri = Uri.parse(
        'http://${server.address.host}:${server.port}/auth/v1/health',
      );
      final checker = BackendReachabilityChecker(
        client: client,
        backendUri: uri,
        headers: const {'apikey': 'my-anon-key'},
      );
      expect(await checker.check(), BackendReachability.reachable);
      expect(capturedApikey, 'my-anon-key');
    });
  });
  group('HttpReachabilityClient (real HttpServer)', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
    });

    Uri serverUri(String path) =>
        Uri.parse('http://${server.address.host}:${server.port}$path');

    test('200 JSON -> reachable', () async {
      server.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.statusCode = 200;
        req.response.write('{"ok":true}');
        await req.response.close();
      });
      final checker = BackendReachabilityChecker(
        client: HttpReachabilityClient(),
        backendUri: serverUri('/health'),
        timeout: const Duration(seconds: 2),
      );
      expect(await checker.check(), BackendReachability.reachable);
    });

    test('200 text/html -> backendUnreachable', () async {
      server.listen((req) async {
        req.response.headers.contentType = ContentType.html;
        req.response.statusCode = 200;
        req.response.write('<html><body>Login</body></html>');
        await req.response.close();
      });
      final checker = BackendReachabilityChecker(
        client: HttpReachabilityClient(),
        backendUri: serverUri('/'),
        timeout: const Duration(seconds: 2),
      );
      expect(await checker.check(), BackendReachability.backendUnreachable);
    });

    test('200 text/plain with html body -> backendUnreachable', () async {
      server.listen((req) async {
        req.response.headers.contentType = ContentType('text', 'plain');
        req.response.statusCode = 200;
        req.response.write('<head><meta>portal</head>');
        await req.response.close();
      });
      final checker = BackendReachabilityChecker(
        client: HttpReachabilityClient(),
        backendUri: serverUri('/'),
        timeout: const Duration(seconds: 2),
      );
      expect(await checker.check(), BackendReachability.backendUnreachable);
    });

    test('redirect to HTML portal -> backendUnreachable', () async {
      server.listen((req) async {
        if (req.uri.path == '/start') {
          req.response.statusCode = 302;
          req.response.headers.set('location', serverUri('/portal').toString());
          await req.response.close();
        } else if (req.uri.path == '/portal') {
          req.response.headers.contentType = ContentType.html;
          req.response.statusCode = 200;
          req.response.write('<html>portal login</html>');
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
      final checker = BackendReachabilityChecker(
        client: HttpReachabilityClient(),
        backendUri: serverUri('/start'),
        timeout: const Duration(seconds: 2),
      );
      // HttpClient follows redirects; final response is 200 HTML -> portal.
      expect(await checker.check(), BackendReachability.backendUnreachable);
    });

    test('hanging server -> backendUnreachable within timeout', () async {
      server.listen((req) async {
        // Never respond; checker must timeout.
        await Future.delayed(const Duration(seconds: 5));
        try {
          req.response.statusCode = 200;
          await req.response.close();
        } catch (_) {}
      });
      final checker = BackendReachabilityChecker(
        client: HttpReachabilityClient(),
        backendUri: serverUri('/hang'),
        timeout: const Duration(milliseconds: 200),
      );
      final sw = Stopwatch()..start();
      final result = await checker.check();
      sw.stop();
      expect(result, BackendReachability.backendUnreachable);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('non-2xx from real server -> backendUnreachable', () async {
      server.listen((req) async {
        req.response.statusCode = 503;
        req.response.write('Service Unavailable');
        await req.response.close();
      });
      final checker = BackendReachabilityChecker(
        client: HttpReachabilityClient(),
        backendUri: serverUri('/'),
        timeout: const Duration(seconds: 2),
      );
      expect(await checker.check(), BackendReachability.backendUnreachable);
    });
  });
}
