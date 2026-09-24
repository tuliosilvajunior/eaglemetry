import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';
import 'package:capy_companion/abrp/abrp_client.dart';
import 'package:capy_companion/abrp/abrp_settings_store.dart';
import 'package:capy_companion/abrp/abrp_telemetry_forwarder.dart';

void main() {
  group('AbrpClient', () {
    test(
      'sends formatted telemetry payload and handles success response',
      () async {
        final mockHttpServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        String? capturedApiKey;
        String? capturedToken;
        Map<String, dynamic>? capturedBody;

        mockHttpServer.listen((HttpRequest request) async {
          capturedApiKey = request.uri.queryParameters['api_key'];
          capturedToken = request.uri.queryParameters['token'];
          final bodyStr = await utf8.decodeStream(request);
          capturedBody = jsonDecode(bodyStr) as Map<String, dynamic>;

          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'ok'}))
            ..close();
        });

        final client = AbrpClient(
          baseUrl:
              'http://${mockHttpServer.address.host}:${mockHttpServer.port}/1/tlm/send',
          apiKey: 'test-api-key',
        );

        final snapshot = LiveTelemetrySnapshot(
          utcMillis: 1724443200000,
          socPercent: 80.0,
          speedKmh: 60.0,
          powerKw: 15.0,
          isCharging: false,
          latitude: -23.55,
          longitude: -46.63,
        );

        final result = await client.sendTelemetry(
          userToken: 'user-token-abc',
          snapshot: snapshot,
          carModel: 'geely:geometry_e:23:39:other',
        );

        expect(result.isSuccess, isTrue);
        expect(capturedApiKey, 'test-api-key');
        expect(capturedToken, 'user-token-abc');
        expect(capturedBody, isNotNull);
        expect(capturedBody!['tlm'], isNotNull);
        expect((capturedBody!['tlm'] as Map)['soc'], 80.0);
        expect(capturedBody!['car_model'], 'geely:geometry_e:23:39:other');

        await mockHttpServer.close();
      },
    );

    test(
      'the user api key replaces the built-in key in the query and the header',
      () async {
        final mockHttpServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        String? capturedApiKey;
        String? capturedAuth;

        mockHttpServer.listen((HttpRequest request) async {
          capturedApiKey = request.uri.queryParameters['api_key'];
          capturedAuth = request.headers.value('Authorization');
          await utf8.decodeStream(request);
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'ok'}))
            ..close();
        });

        final client = AbrpClient(
          baseUrl:
              'http://${mockHttpServer.address.host}:${mockHttpServer.port}/1/tlm/send',
          apiKey: 'client-key',
        );

        await client.sendTelemetry(
          userToken: 'user-token-abc',
          snapshot: LiveTelemetrySnapshot(
            utcMillis: 1724443200000,
            isCharging: false,
          ),
          apiKeyOverride: '  user-own-key  ',
        );

        expect(capturedApiKey, 'user-own-key');
        expect(capturedAuth, 'APIKEY user-own-key');

        await mockHttpServer.close();
      },
    );

    test('no api key anywhere refuses the send without a request', () async {
      var requests = 0;
      final mockHttpServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      mockHttpServer.listen((HttpRequest request) async {
        requests++;
        await utf8.decodeStream(request);
        request.response
          ..statusCode = HttpStatus.ok
          ..write(jsonEncode({'status': 'ok'}))
          ..close();
      });

      // The app carries no key of its own, so this is the shipped default.
      final client = AbrpClient(
        baseUrl:
            'http://${mockHttpServer.address.host}:${mockHttpServer.port}/1/tlm/send',
      );

      final result = await client.sendTelemetry(
        userToken: 'user-token-abc',
        snapshot: LiveTelemetrySnapshot(
          utcMillis: 1724443200000,
          isCharging: false,
        ),
        apiKeyOverride: '   ',
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, AbrpClient.missingApiKeyError);
      expect(requests, 0);

      await mockHttpServer.close();
    });

    test('a blank api key override falls back to the client key', () async {
      final mockHttpServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      String? capturedApiKey;

      mockHttpServer.listen((HttpRequest request) async {
        capturedApiKey = request.uri.queryParameters['api_key'];
        await utf8.decodeStream(request);
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'status': 'ok'}))
          ..close();
      });

      final client = AbrpClient(
        baseUrl:
            'http://${mockHttpServer.address.host}:${mockHttpServer.port}/1/tlm/send',
        apiKey: 'client-key',
      );

      await client.sendTelemetry(
        userToken: 'user-token-abc',
        snapshot: LiveTelemetrySnapshot(
          utcMillis: 1724443200000,
          isCharging: false,
        ),
        apiKeyOverride: '   ',
      );

      expect(capturedApiKey, 'client-key');

      await mockHttpServer.close();
    });

    test('handles authentication and network errors gracefully', () async {
      final mockHttpServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      mockHttpServer.listen((HttpRequest request) async {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..write(
            jsonEncode({'status': 'error', 'message': 'Invalid user token'}),
          )
          ..close();
      });

      final client = AbrpClient(
        baseUrl:
            'http://${mockHttpServer.address.host}:${mockHttpServer.port}/1/tlm/send',
        apiKey: 'test-api-key',
      );

      final snapshot = LiveTelemetrySnapshot(utcMillis: 1724443200000);
      final result = await client.sendTelemetry(
        userToken: 'invalid-token',
        snapshot: snapshot,
      );

      expect(result.isSuccess, isFalse);
      expect(result.statusCode, 401);
      expect(result.errorMessage, contains('Invalid user token'));

      await mockHttpServer.close();
    });

    test(
      'checks Authorization header and handles HTTP 200 with status error',
      () async {
        final mockHttpServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        String? authHeader;

        mockHttpServer.listen((HttpRequest request) async {
          authHeader = request.headers.value('Authorization');
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({'status': 'error', 'message': 'Unknown user token'}),
            )
            ..close();
        });

        final client = AbrpClient(
          baseUrl:
              'http://${mockHttpServer.address.host}:${mockHttpServer.port}/1/tlm/send',
          apiKey: 'test-api-key',
        );

        final snapshot = LiveTelemetrySnapshot(utcMillis: 1724443200000);
        final result = await client.sendTelemetry(
          userToken: 'token-with-error',
          snapshot: snapshot,
        );

        expect(authHeader, 'APIKEY test-api-key');
        expect(result.isSuccess, isFalse);
        expect(result.errorMessage, contains('Unknown user token'));

        await mockHttpServer.close();
      },
    );
  });

  group('AbrpTelemetryForwarder', () {
    test('enforces upload interval cadence', () async {
      final settings = FileAbrpSettingsStore(
        enabled: true,
        userToken: 'valid-token',
        apiKey: 'user-own-key',
        uploadIntervalSeconds: 5,
      );

      int uploadCount = 0;
      final forwarder = AbrpTelemetryForwarder(
        settingsStore: settings,
        clientSender: (snapshot, token) async {
          uploadCount++;
          return const AbrpSendResult(isSuccess: true, statusCode: 200);
        },
      );

      final t0 = 1724443200000;
      final snap1 = LiveTelemetrySnapshot(utcMillis: t0, socPercent: 80.0);
      final snap2 = LiveTelemetrySnapshot(
        utcMillis: t0 + 2000,
        socPercent: 79.9,
      ); // +2s (rate-limited)
      final snap3 = LiveTelemetrySnapshot(
        utcMillis: t0 + 6000,
        socPercent: 79.8,
      ); // +6s (allowed)

      await forwarder.onSnapshotReceived(snap1);
      expect(uploadCount, 1);
      expect(forwarder.status.state, AbrpForwarderState.streaming);

      await forwarder.onSnapshotReceived(snap2);
      expect(uploadCount, 1); // skipped due to cadence

      await forwarder.onSnapshotReceived(snap3);
      expect(uploadCount, 2); // forwarded
    });

    test('does not upload when the api key is missing', () async {
      // The app carries no key of its own, so an unset key is the state a
      // fresh install is in, not an unlikely one.
      final settings = FileAbrpSettingsStore(
        enabled: true,
        userToken: 'valid-token',
      );

      var uploadCount = 0;
      final forwarder = AbrpTelemetryForwarder(
        settingsStore: settings,
        clientSender: (snapshot, token) async {
          uploadCount++;
          return const AbrpSendResult(isSuccess: true, statusCode: 200);
        },
      );

      expect(forwarder.status.state, AbrpForwarderState.disabled);
      expect(forwarder.status.lastError, AbrpClient.missingApiKeyError);

      await forwarder.onSnapshotReceived(
        LiveTelemetrySnapshot(utcMillis: 1724443200000, socPercent: 80.0),
      );

      expect(uploadCount, 0);

      // Setting the key later lifts the block without a restart.
      await settings.setApiKey('user-own-key');
      await forwarder.onSnapshotReceived(
        LiveTelemetrySnapshot(utcMillis: 1724443200000, socPercent: 80.0),
      );

      expect(uploadCount, 1);
      expect(forwarder.status.state, AbrpForwarderState.streaming);
    });

    test('does not upload when disabled or token missing', () async {
      final settings = FileAbrpSettingsStore(enabled: false, userToken: null);

      int uploadCount = 0;
      final forwarder = AbrpTelemetryForwarder(
        settingsStore: settings,
        clientSender: (snapshot, token) async {
          uploadCount++;
          return const AbrpSendResult(isSuccess: true, statusCode: 200);
        },
      );

      await forwarder.onSnapshotReceived(
        LiveTelemetrySnapshot(utcMillis: 1724443200000),
      );
      expect(uploadCount, 0);
      expect(forwarder.status.state, AbrpForwarderState.disabled);
    });
  });

  group('FileAbrpSettingsStore', () {
    test(
      'persists and restores token, api key, enabled, and interval across instances',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('abrp_test_');
        try {
          final store1 = FileAbrpSettingsStore(directory: tempDir);
          await store1.load();
          expect(store1.enabled, isFalse);
          expect(store1.userToken, isNull);
          expect(store1.apiKey, isNull);

          await store1.setEnabled(true);
          await store1.setUserToken('saved-abrp-token-123');
          await store1.setApiKey('saved-api-key-456');
          await store1.setUploadIntervalSeconds(10);
          await store1.setCarModel('custom:model:id');

          // New store instance loading from same directory
          final store2 = FileAbrpSettingsStore(directory: tempDir);
          await store2.load();

          expect(store2.enabled, isTrue);
          expect(store2.userToken, 'saved-abrp-token-123');
          expect(store2.apiKey, 'saved-api-key-456');
          expect(store2.uploadIntervalSeconds, 10);
          expect(store2.carModel, 'custom:model:id');

          // A blank api key clears the setting and falls back to the built-in key.
          await store2.setApiKey('   ');
          final store3 = FileAbrpSettingsStore(directory: tempDir);
          await store3.load();
          expect(store3.apiKey, isNull);
        } finally {
          await tempDir.delete(recursive: true);
        }
      },
    );
  });
}
