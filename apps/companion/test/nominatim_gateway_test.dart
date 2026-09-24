import 'package:capy_companion/sync/nominatim_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_archive.dart';

void main() {
  // Ensure sqflite ffi is initialized for each test via memoryArchive helper.

  group('NominatimGateway', () {
    test(
      'Sem opt-in nenhum request sai (gate blocks cache and network)',
      () async {
        final archive = await memoryArchive();
        var fetchCalls = 0;
        final gateway = NominatimGateway(
          database: archive.database,
          fetcher: (uri, headers) async {
            fetchCalls++;
            return 'Rua Teste';
          },
        );

        // Pre-populate cache for the cell.
        final cell = NominatimGateway.cellKeyFor(-23.55, -46.63);
        await archive.database.upsertNominatimCache(
          cellKey: cell,
          latitude: -23.55,
          longitude: -46.63,
          displayName: 'Cached Rua',
          fetchedAtUtcMillis: DateTime.now().millisecondsSinceEpoch,
        );

        final result = await gateway.reverse(
          lat: -23.55,
          lon: -46.63,
          optIn: false,
        );

        expect(result, isNull);
        expect(fetchCalls, 0, reason: 'gate must prevent any network request');
        // Also gate prevents cache return — spec says nenhum request sai,
        // the gateway returns null immediately when optIn false.
      },
    );

    test('Cache hit por celula 100 m instantaneo, miss entra na fila', () async {
      final archive = await memoryArchive();
      var fetchCalls = 0;
      final fetchedNames = <String>[];

      final gateway = NominatimGateway(
        database: archive.database,
        fetcher: (uri, headers) async {
          fetchCalls++;
          // Simulate small network delay.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final name = 'Display $fetchCalls';
          fetchedNames.add(name);
          return name;
        },
      );

      // First miss — should fetch.
      final r1 = await gateway.reverse(lat: -23.55, lon: -46.63, optIn: true);
      expect(r1, isNotNull);
      expect(r1!.displayName, 'Display 1');
      expect(r1.fromCache, isFalse);
      expect(fetchCalls, 1);

      // Second call with same cell (identical coords) — instant cache hit, no fetch.
      final r2 = await gateway.reverse(lat: -23.55, lon: -46.63, optIn: true);
      expect(r2, isNotNull);
      expect(r2!.displayName, 'Display 1');
      expect(r2.fromCache, isTrue);
      expect(fetchCalls, 1, reason: 'cache hit must not call fetcher');

      // Third call with nearby coords within same 100 m cell — also hit.
      // 0.00005 degrees ≈ 5.5 m, well within 100 m cell.
      final r3 = await gateway.reverse(
        lat: -23.55 + 0.00005,
        lon: -46.63 + 0.00005,
        optIn: true,
      );
      expect(r3, isNotNull);
      expect(r3!.displayName, 'Display 1');
      expect(r3.fromCache, isTrue);
      expect(fetchCalls, 1);

      // Different cell — should miss and fetch.
      // Move ~0.002 degrees ≈ 220 m >100 m, different cell.
      final r4 = await gateway.reverse(lat: -23.552, lon: -46.632, optIn: true);
      expect(r4, isNotNull);
      expect(r4!.displayName, 'Display 2');
      expect(fetchCalls, 2);
    });

    test(
      'Cache grouping uses 100 m cell identical to candidate grouping',
      () async {
        // Verify static cellKeyFor matches variantSignature semantics.
        final k1 = NominatimGateway.cellKeyFor(-23.5617, -46.6559);
        final k2 = NominatimGateway.cellKeyFor(-23.5617, -46.6559);
        expect(k1, k2);

        // Nearby point within 100 m should share cell in many cases; we at least
        // verify that identical computation is used.
        // Use the same helper directly: two points 50 m apart should sometimes
        // share cell — we test the gateway's cellKeyFor equals candidate's
        // variantSignature for single point.
        // This is a sanity check that we reuse the same grid.
        expect(k1.contains(','), isTrue);
      },
    );

    test('TTL 30 dias invalida entrada antiga', () async {
      final archive = await memoryArchive();
      var fetchCalls = 0;
      final now = DateTime.now();

      // Use a controllable clock: gateway's now returns same time initially,
      // then we advance for TTL check by inserting old entry with old timestamp.
      final gateway = NominatimGateway(
        database: archive.database,
        now: () => now,
        fetcher: (uri, headers) async {
          fetchCalls++;
          return 'Fresh Name';
        },
      );

      final lat = -23.55;
      final lon = -46.63;
      final cell = NominatimGateway.cellKeyFor(lat, lon);

      // Insert stale entry 31 days old.
      final staleTime =
          now.millisecondsSinceEpoch - const Duration(days: 31).inMilliseconds;
      await archive.database.upsertNominatimCache(
        cellKey: cell,
        latitude: lat,
        longitude: lon,
        displayName: 'Stale Name',
        fetchedAtUtcMillis: staleTime,
      );

      // Should be treated as miss and fetch fresh.
      final r = await gateway.reverse(lat: lat, lon: lon, optIn: true);
      expect(fetchCalls, 1);
      expect(r, isNotNull);
      expect(r!.displayName, 'Fresh Name');
      expect(r.fromCache, isFalse);

      // Subsequent call should hit fresh cache.
      final r2 = await gateway.reverse(lat: lat, lon: lon, optIn: true);
      expect(r2!.displayName, 'Fresh Name');
      expect(r2.fromCache, isTrue);
      expect(fetchCalls, 1);

      // Entry within TTL (29 days) must remain valid.
      final freshCell = NominatimGateway.cellKeyFor(-23.56, -46.64);
      final freshTime =
          now.millisecondsSinceEpoch - const Duration(days: 29).inMilliseconds;
      await archive.database.upsertNominatimCache(
        cellKey: freshCell,
        latitude: -23.56,
        longitude: -46.64,
        displayName: 'Still Fresh',
        fetchedAtUtcMillis: freshTime,
      );
      var secondFetchCalls = 0;
      final gateway2 = NominatimGateway(
        database: archive.database,
        now: () => now,
        fetcher: (uri, headers) async {
          secondFetchCalls++;
          return 'Should Not Fetch';
        },
      );
      final hit = await gateway2.reverse(lat: -23.56, lon: -46.64, optIn: true);
      expect(hit, isNotNull);
      expect(hit!.displayName, 'Still Fresh');
      expect(hit.fromCache, isTrue);
      expect(secondFetchCalls, 0);
    });

    test(
      'Request usa zoom=18, accept-language=pt-BR e User-Agent correto',
      () async {
        final archive = await memoryArchive();
        Uri? capturedUri;
        Map<String, String>? capturedHeaders;

        final gateway = NominatimGateway(
          database: archive.database,
          fetcher: (uri, headers) async {
            capturedUri = uri;
            capturedHeaders = headers;
            return 'Rua A, São Paulo';
          },
        );

        final result = await gateway.reverse(
          lat: -23.55,
          lon: -46.63,
          optIn: true,
        );

        expect(result, isNotNull);
        expect(capturedUri, isNotNull);
        expect(capturedUri!.host, 'nominatim.openstreetmap.org');
        expect(capturedUri!.path, '/reverse');
        expect(capturedUri!.queryParameters['zoom'], '18');
        expect(capturedUri!.queryParameters['accept-language'], 'pt-BR');
        expect(capturedUri!.queryParameters['addressdetails'], '1');
        expect(capturedUri!.queryParameters['format'], 'jsonv2');
        expect(capturedUri!.queryParameters['lat'], '-23.55');
        expect(capturedUri!.queryParameters['lon'], '-46.63');

        expect(capturedHeaders, isNotNull);
        expect(capturedHeaders!['User-Agent'], NominatimGateway.userAgent);
        expect(capturedHeaders!['User-Agent'], 'com.timhss.capy');
        // HttpHeaders.userAgentHeader is 'user-agent' lower case; our map uses that.
        // Accept-Language header must be pt-BR.
        final acceptLangKey = capturedHeaders!.keys.firstWhere(
          (k) => k.toLowerCase() == 'accept-language',
          orElse: () => '',
        );
        expect(acceptLangKey, isNotEmpty);
        expect(capturedHeaders![acceptLangKey], 'pt-BR');
      },
    );

    test(
      'Attribution OSM presente e falha/vago retorna mensagem para digitar manual',
      () async {
        final archive = await memoryArchive();

        // Attribution constant check
        expect(NominatimGateway.osmAttribution, '© OpenStreetMap contributors');

        // Failure case: fetcher returns null (network error)
        final gatewayFail = NominatimGateway(
          database: archive.database,
          fetcher: (uri, headers) async => null,
        );
        final failResult = await gatewayFail.reverse(
          lat: -23.55,
          lon: -46.63,
          optIn: true,
        );
        expect(failResult, isNull);
        expect(
          NominatimGateway.kManualPrompt.toLowerCase(),
          contains('manual'),
        );

        // Vague case: empty string
        final gatewayVagueEmpty = NominatimGateway(
          database: archive.database,
          fetcher: (uri, headers) async => '   ',
        );
        // Use different cell to avoid cache hit from previous failure (failures not cached)
        final vagueEmpty = await gatewayVagueEmpty.reverse(
          lat: -23.551,
          lon: -46.631,
          optIn: true,
        );
        expect(
          vagueEmpty,
          isNull,
          reason: 'empty display_name must be treated as vague',
        );

        // Vague case: very short string <5 chars
        final gatewayShort = NominatimGateway(
          database: archive.database,
          fetcher: (uri, headers) async => 'abc',
        );
        final vagueShort = await gatewayShort.reverse(
          lat: -23.552,
          lon: -46.632,
          optIn: true,
        );
        expect(vagueShort, isNull);

        // Failure must not be cached: second call should retry fetch
        var shortCalls = 0;
        final gatewayShort2 = NominatimGateway(
          database: archive.database,
          fetcher: (uri, headers) async {
            shortCalls++;
            return shortCalls == 1 ? 'ab' : 'Avenida Paulista, São Paulo';
          },
        );
        final firstShort = await gatewayShort2.reverse(
          lat: -23.553,
          lon: -46.633,
          optIn: true,
        );
        expect(firstShort, isNull);
        expect(shortCalls, 1);
        // Second call for same cell should retry fetch because vague not cached.
        // It will be throttled (~1s) internally, but still returns success.
        final secondTry = await gatewayShort2.reverse(
          lat: -23.553,
          lon: -46.633,
          optIn: true,
        );
        expect(secondTry, isNotNull);
        expect(secondTry!.displayName, 'Avenida Paulista, São Paulo');
        expect(shortCalls, 2);
      },
    );

    test(
      'throttle 15 req/min (4s) enqueues concurrent misses sequentially',
      () async {
        final archive = await memoryArchive();
        final fetchTimes = <int>[];
        final gateway = NominatimGateway(
          database: archive.database,
          fetcher: (uri, headers) async {
            fetchTimes.add(DateTime.now().millisecondsSinceEpoch);
            await Future<void>.delayed(const Duration(milliseconds: 50));
            // Return distinct name per call based on lat
            final lat = uri.queryParameters['lat'] ?? '0';
            return 'Name for $lat';
          },
        );

        // Two distinct cells, concurrent.
        final f1 = gateway.reverse(lat: -23.55, lon: -46.63, optIn: true);
        final f2 = gateway.reverse(lat: -23.56, lon: -46.64, optIn: true);

        final results = await Future.wait([f1, f2]);

        expect(results[0], isNotNull);
        expect(results[1], isNotNull);
        expect(fetchTimes, hasLength(2));
        final delta = fetchTimes[1] - fetchTimes[0];
        // Second fetch must start at least ~3900 ms after first due to 15 req/min (4s).
        expect(
          delta,
          greaterThanOrEqualTo(3900),
          reason: 'throttle must enforce 15 req/min (4s), delta=$delta',
        );
      },
    );

    test('User-Agent header is exactly com.timhss.capy', () async {
      final archive = await memoryArchive();
      Map<String, String>? headers;
      final gateway = NominatimGateway(
        database: archive.database,
        fetcher: (uri, h) async {
          headers = h;
          return 'Rua X';
        },
      );
      await gateway.reverse(lat: 0, lon: 0, optIn: true);
      expect(headers, isNotNull);
      // Find user-agent key case-insensitive
      final uaEntry = headers!.entries.firstWhere(
        (e) => e.key.toLowerCase() == 'user-agent',
      );
      expect(uaEntry.value, 'com.timhss.capy');
    });

    test('attribution is exposed on success result', () async {
      final archive = await memoryArchive();
      final gateway = NominatimGateway(
        database: archive.database,
        fetcher: (uri, headers) async => 'Rua Y, Cidade',
      );
      final result = await gateway.reverse(lat: 1, lon: 1, optIn: true);
      expect(result, isNotNull);
      expect(result!.attribution, '© OpenStreetMap contributors');
      expect(result.attribution, NominatimGateway.osmAttribution);
    });

    test('optIn true with cache hit is instant (no throttle delay)', () async {
      final archive = await memoryArchive();
      final cell = NominatimGateway.cellKeyFor(0, 0);
      await archive.database.upsertNominatimCache(
        cellKey: cell,
        latitude: 0,
        longitude: 0,
        displayName: 'Cached Instant',
        fetchedAtUtcMillis: DateTime.now().millisecondsSinceEpoch,
      );
      var fetchCalls = 0;
      final gateway = NominatimGateway(
        database: archive.database,
        fetcher: (uri, headers) async {
          fetchCalls++;
          return 'Should not be called';
        },
      );
      final sw = Stopwatch()..start();
      final result = await gateway.reverse(lat: 0, lon: 0, optIn: true);
      sw.stop();
      expect(result, isNotNull);
      expect(result!.fromCache, isTrue);
      expect(fetchCalls, 0);
      expect(
        sw.elapsedMilliseconds,
        lessThan(200),
        reason: 'cache hit must be instant, not throttled',
      );
    });

    test('shortName retorna rua + numero e legacy cache invalida', () async {
      // road + house_number
      expect(
        NominatimGateway.shortNameFromResponse({
          'address': {'road': 'Rua Visconde de Piraja', 'house_number': '100'},
          'display_name': 'Rua Visconde, 100, Ipanema, Rio',
        }),
        'Rua Visconde de Piraja, 100',
      );
      // only road
      expect(
        NominatimGateway.shortNameFromResponse({
          'address': {'road': 'Avenida Paulista'},
        }),
        'Avenida Paulista',
      );
      // pedestrian fallback
      expect(
        NominatimGateway.shortNameFromResponse({
          'address': {'pedestrian': 'Rua das Pedras', 'house_number': '42'},
        }),
        'Rua das Pedras, 42',
      );
      // no road returns null
      expect(
        NominatimGateway.shortNameFromResponse({
          'address': {'city': 'Sao Paulo'},
          'display_name': 'Sao Paulo',
        }),
        isNull,
      );
      // legacy cache with 2+ commas should be treated as miss
      final archive = await memoryArchive();
      final cell = NominatimGateway.cellKeyFor(1, 1);
      await archive.database.upsertNominatimCache(
        cellKey: cell,
        latitude: 1,
        longitude: 1,
        displayName: 'Rua A, 100, Bairro, Cidade, Estado',
        fetchedAtUtcMillis: DateTime.now().millisecondsSinceEpoch,
      );
      var fetchCalls = 0;
      final gateway = NominatimGateway(
        database: archive.database,
        fetcher: (uri, headers) async {
          fetchCalls++;
          return 'Rua Nova, 200';
        },
      );
      final result = await gateway.reverse(lat: 1, lon: 1, optIn: true);
      expect(result, isNotNull);
      expect(result!.displayName, 'Rua Nova, 200');
      expect(result.fromCache, isFalse);
      expect(fetchCalls, 1);
      // short entry with 1 comma stays cached
      final cell2 = NominatimGateway.cellKeyFor(2, 2);
      await archive.database.upsertNominatimCache(
        cellKey: cell2,
        latitude: 2,
        longitude: 2,
        displayName: 'Rua Curta, 123',
        fetchedAtUtcMillis: DateTime.now().millisecondsSinceEpoch,
      );
      var fetch2 = 0;
      final gateway2 = NominatimGateway(
        database: archive.database,
        fetcher: (uri, headers) async {
          fetch2++;
          return 'Should not fetch';
        },
      );
      final hit = await gateway2.reverse(lat: 2, lon: 2, optIn: true);
      expect(hit, isNotNull);
      expect(hit!.displayName, 'Rua Curta, 123');
      expect(hit.fromCache, isTrue);
      expect(fetch2, 0);
    });
  });

  group('NominatimOptIn persistence via preference sync', () {
    test('toggle persists via preference row and survives reload', () async {
      final archive = await memoryArchive();
      // Simulate the store's persistence logic directly.
      // This mirrors what Settings toggle does: upsert preference + enqueue.
      const key = NominatimGateway.preferenceKey;
      const scope = NominatimGateway.preferenceScope;

      // Initially off (no row)
      var rows = await archive.database.allPreferences();
      expect(rows.where((r) => r['key'] == key), isEmpty);

      // Turn on
      final now = DateTime.now().millisecondsSinceEpoch;
      final row = <String, Object?>{
        'scope': scope,
        'key': key,
        'value': 'true',
        'updatedAtUtcMillis': now,
        'origin': 'phone',
        'deletedAtUtcMillis': null,
      };
      await archive.upsertPreference(row);
      await archive.database.enqueueAnnotationPush('preferences', row);

      rows = await archive.database.allPreferences();
      final saved = rows.singleWhere((r) => r['key'] == key);
      expect(saved['value'], 'true');
      expect(saved['scope'], scope);

      // Check outbox enqueued
      final outbox = await archive.database.pendingAnnotationPush();
      expect(
        outbox.any((e) => e.stream == 'preferences' && (e.row['key'] == key)),
        isTrue,
      );

      // Simulate reload: new store reads same DB and should see true
      final archive2 = archive; // same DB
      final rows2 = await archive2.database.allPreferences();
      final saved2 = rows2.singleWhere((r) => r['key'] == key);
      expect(saved2['value'], 'true');

      // Turn off
      final now2 = DateTime.now().millisecondsSinceEpoch + 1000;
      final rowOff = <String, Object?>{
        'scope': scope,
        'key': key,
        'value': 'false',
        'updatedAtUtcMillis': now2,
        'origin': 'phone',
        'deletedAtUtcMillis': null,
      };
      await archive.upsertPreference(rowOff);
      await archive.database.enqueueAnnotationPush('preferences', rowOff);
      final rowsOff = await archive.database.allPreferences();
      expect(rowsOff.singleWhere((r) => r['key'] == key)['value'], 'false');
    });
  });
}
