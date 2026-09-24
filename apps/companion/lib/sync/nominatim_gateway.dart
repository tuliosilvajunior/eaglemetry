import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:telemetry_core/telemetry_core.dart';

import 'companion_database.dart';

/// Companion-only reverse geocode via Nominatim.
///
/// - Opt-in gate: when [optIn] is false no request leaves.
/// - Cache per 100 m cell ([kInsightVariantGridM] via [variantSignature]), TTL 30 days.
/// - Throttle 15 req/min (4 s) sequential even under concurrent callers.
/// - Request: zoom=18, accept-language=pt-BR, addressdetails=1, User-Agent com.timhss.capy.
/// - Attribution OSM always exposed.
class NominatimGateway {
  NominatimGateway({
    required this.database,
    HttpClient Function()? clientFactory,
    DateTime Function()? now,
    this.fetcher,
  }) : _clientFactory = clientFactory ?? (() => HttpClient()),
       _now = now ?? DateTime.now;

  final CompanionDatabase database;
  final HttpClient Function() _clientFactory;
  final DateTime Function() _now;

  /// Test override: when set, [_fetch] calls this instead of HttpClient.
  final Future<String?> Function(Uri uri, Map<String, String> headers)? fetcher;

  static const String osmAttribution = '© OpenStreetMap contributors';
  static const String userAgent = 'com.timhss.capy';
  static const Duration cacheTtl = Duration(days: 30);
  static const Duration throttleInterval = Duration(seconds: 4);
  static const String kManualPrompt =
      'Não foi possível obter o endereço. Digite manualmente.';

  /// The preference that gates the gateway. Companion-only, default off.
  static const String preferenceKey = 'places.nominatimOptIn';
  static const String preferenceScope = kPreferenceScopeDevice;

  /// Computes the 100 m cell key identical to Candidate Place grouping.
  static String cellKeyFor(double latitude, double longitude) {
    return _computeCellKey(latitude, longitude);
  }

  static String _computeCellKey(double latitude, double longitude) {
    // Mirrors variantSignature([InsightPoint]) for a single point.
    // Uses kInsightVariantGridM and _metersPerDegree from insight_place.dart
    // to keep grouping identical to deriveCandidatePlaces.
    const metersPerDegree = 111320.0;
    final latM = latitude * metersPerDegree;
    final lonM =
        longitude * metersPerDegree * math.cos(latitude * math.pi / 180);
    final latCell = (latM / kInsightVariantGridM).round();
    final lonCell = (lonM / kInsightVariantGridM).round();
    return '$latCell,$lonCell';
  }

  bool _isVague(String? displayName) {
    if (displayName == null) return true;
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return true;
    if (trimmed.length < 5) return true;
    return false;
  }

  Future<NominatimResult?> _readCached(String cellKey) async {
    final row = await database.nominatimCacheFor(cellKey);
    if (row == null) return null;
    final fetchedAt = (row['fetchedAtUtcMillis'] as num?)?.toInt();
    if (fetchedAt == null) return null;
    final age = _now().millisecondsSinceEpoch - fetchedAt;
    if (age > cacheTtl.inMilliseconds) {
      // TTL expired — treat as miss but do not delete eagerly; fetch will
      // overwrite. Keep instant miss path.
      return null;
    }
    final lat = (row['latitude'] as num?)?.toDouble();
    final lon = (row['longitude'] as num?)?.toDouble();
    final displayName = row['displayName'] as String?;
    if (lat == null || lon == null || displayName == null) return null;
    if (_isVague(displayName)) return null;
    // Legacy long display_name (road, num, bairro, cidade, ...) had 2+ commas.
    // Short names have at most 1 comma (road, number). Force refetch to get short.
    if (displayName.split(',').length > 2) return null;
    return NominatimResult(
      cellKey: cellKey,
      latitude: lat,
      longitude: lon,
      displayName: displayName,
      attribution: osmAttribution,
      fetchedAtUtcMillis: fetchedAt,
      fromCache: true,
    );
  }

  Future<void> _writeCache({
    required String cellKey,
    required double latitude,
    required double longitude,
    required String displayName,
  }) async {
    await database.upsertNominatimCache(
      cellKey: cellKey,
      latitude: latitude,
      longitude: longitude,
      displayName: displayName,
      fetchedAtUtcMillis: _now().millisecondsSinceEpoch,
    );
  }

  // Sequential 15 req/min (4 s) queue.
  Future<void> _tail = Future<void>.value();
  int? _lastRequestMs;

  Future<T> _withThrottle<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      final nowMs = _now().millisecondsSinceEpoch;
      if (_lastRequestMs != null) {
        final elapsed = nowMs - _lastRequestMs!;
        final needed = throttleInterval.inMilliseconds - elapsed;
        if (needed > 0) {
          await Future<void>.delayed(Duration(milliseconds: needed));
        }
      }
      _lastRequestMs = _now().millisecondsSinceEpoch;
      try {
        final result = await action();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Reverse geocode [lat]/[lon].
  ///
  /// Returns null when gated ([optIn] false), when the response is vague, or
  /// on any failure. Caller shows [kManualPrompt] in those cases.
  Future<NominatimResult?> reverse({
    required double lat,
    required double lon,
    required bool optIn,
  }) async {
    if (!optIn) return null;
    if (!lat.isFinite || !lon.isFinite) return null;

    final cellKey = _computeCellKey(lat, lon);

    final cached = await _readCached(cellKey);
    if (cached != null) return cached;

    return _withThrottle(() async {
      // Re-check after throttle wait — another concurrent call may have filled it.
      final rechecked = await _readCached(cellKey);
      if (rechecked != null) return rechecked;

      final fetched = await _fetch(lat: lat, lon: lon);
      if (fetched == null || _isVague(fetched)) return null;

      await _writeCache(
        cellKey: cellKey,
        latitude: lat,
        longitude: lon,
        displayName: fetched,
      );
      final nowMs = _now().millisecondsSinceEpoch;
      return NominatimResult(
        cellKey: cellKey,
        latitude: lat,
        longitude: lon,
        displayName: fetched,
        attribution: osmAttribution,
        fetchedAtUtcMillis: nowMs,
        fromCache: false,
      );
    });
  }

  static String? shortNameFromResponse(Map<String, dynamic> decoded) {
    final address = decoded['address'] as Map<String, dynamic>?;
    if (address != null) {
      const roadKeys = [
        'road',
        'pedestrian',
        'footway',
        'path',
        'residential',
        'living_street',
        'highway',
        'bridge',
        'tunnel',
        'service',
        'unclassified',
        'primary',
        'secondary',
        'tertiary',
      ];
      String? road;
      for (final k in roadKeys) {
        final v = address[k] as String?;
        if (v != null && v.trim().isNotEmpty) {
          road = v.trim();
          break;
        }
      }
      final house = (address['house_number'] as String?)?.trim();
      if (road != null && road.isNotEmpty) {
        if (house != null && house.isNotEmpty) return '$road, $house';
        return road;
      }
      if (house != null && house.isNotEmpty) return house;
    }
    return null;
  }

  Future<String?> _fetch({required double lat, required double lon}) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'format': 'jsonv2',
      'lat': lat.toString(),
      'lon': lon.toString(),
      'zoom': '18',
      'accept-language': 'pt-BR',
      'addressdetails': '1',
    });
    final headers = <String, String>{
      'User-Agent': userAgent,
      'Accept-Language': 'pt-BR',
      HttpHeaders.acceptHeader: 'application/json',
    };

    final customFetcher = fetcher;
    if (customFetcher != null) {
      try {
        return await customFetcher(uri, headers);
      } catch (_) {
        return null;
      }
    }

    HttpClient client;
    try {
      client = _clientFactory();
    } catch (_) {
      return null;
    }

    try {
      final request = await client.getUrl(uri);
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }

      final response = await request.close();

      if (response.statusCode != HttpStatus.ok) {
        // Drain to avoid leaking connection.
        try {
          await response.drain<void>();
        } catch (_) {}
        return null;
      }

      final body = await utf8.decodeStream(response);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final short = shortNameFromResponse(decoded);
      if (short != null && short.trim().isNotEmpty) return short.trim();
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// Success result of [NominatimGateway.reverse].
class NominatimResult {
  const NominatimResult({
    required this.cellKey,
    required this.latitude,
    required this.longitude,
    required this.displayName,
    required this.attribution,
    required this.fetchedAtUtcMillis,
    required this.fromCache,
  });

  final String cellKey;
  final double latitude;
  final double longitude;
  final String displayName;
  final String attribution;
  final int fetchedAtUtcMillis;
  final bool fromCache;
}
