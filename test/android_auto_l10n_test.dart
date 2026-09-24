import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/l10n/app_localizations_en.dart';
import 'package:capy_energy/l10n/app_localizations_pt.dart';
import 'package:capy_energy/l10n/app_localizations_ru.dart';

/// Parity guard for the Android Auto keys.
///
/// A key missing from `app_pt.arb` or `app_ru.arb` falls back to English
/// silently at runtime; this test turns that into a red build.
void main() {
  final en = AppLocalizationsEn();
  final pt = AppLocalizationsPt();
  final ru = AppLocalizationsRu();

  const proseKeys = [
    'v2AndroidAutoUnavailable',
    'v2AndroidAutoConnecting',
    'v2AndroidAutoBlackScreenHint',
    'v2AndroidAutoDragHandle',
    'v2AndroidAutoReattach',
    'v2AndroidAutoStateAvailable',
    'v2AndroidAutoStateBound',
    'v2AndroidAutoStateAttached',
    'v2AndroidAutoErrorUnreachable',
    'v2AndroidAutoErrorRenderer',
    'v2AndroidAutoErrorBuffer',
    'v2AndroidAutoErrorGeneric',
  ];

  for (final entry in {'en': en, 'pt': pt, 'ru': ru}.entries) {
    test('${entry.key}: every Android Auto key is present', () {
      final loc = entry.value;
      expect(loc.navAndroidAuto, isNotEmpty);
      expect(loc.v2AndroidAutoTitle, isNotEmpty);
      expect(loc.v2AndroidAutoStatusTitle, isNotEmpty);
      expect(loc.v2AndroidAutoUnavailable, isNotEmpty);
      expect(loc.v2AndroidAutoConnecting, isNotEmpty);
      expect(loc.v2AndroidAutoBlackScreenHint, isNotEmpty);
      expect(loc.v2AndroidAutoDragHandle, isNotEmpty);
      expect(loc.v2AndroidAutoReattach, isNotEmpty);
      expect(loc.v2AndroidAutoBuffer, isNotEmpty);
      expect(loc.v2AndroidAutoStateAvailable, isNotEmpty);
      expect(loc.v2AndroidAutoStateBound, isNotEmpty);
      expect(loc.v2AndroidAutoStateAttached, isNotEmpty);
      expect(loc.v2AndroidAutoErrorUnreachable, isNotEmpty);
      expect(loc.v2AndroidAutoErrorRenderer, isNotEmpty);
      expect(loc.v2AndroidAutoErrorBuffer, isNotEmpty);
      expect(loc.v2AndroidAutoErrorGeneric, isNotEmpty);
    });
  }

  test('prose copy is genuinely translated in PT and RU', () {
    for (final key in proseKeys) {
      final enValue = _value(en, key);
      expect(
        _value(pt, key),
        isNot(equals(enValue)),
        reason: '$key is a copy-paste of the English string in PT',
      );
      expect(
        _value(ru, key),
        isNot(equals(enValue)),
        reason: '$key is a copy-paste of the English string in RU',
      );
    }
  });

  test('product-name keys keep the Apple brand in every locale', () {
    expect(pt.navAndroidAuto, 'Android Auto');
    expect(ru.navAndroidAuto, 'Android Auto');
    expect(pt.v2AndroidAutoTitle, 'Android Auto');
    expect(ru.v2AndroidAutoTitle, 'Android Auto');
  });
}

String _value(AppLocalizations loc, String key) {
  return switch (key) {
    'v2AndroidAutoUnavailable' => loc.v2AndroidAutoUnavailable,
    'v2AndroidAutoConnecting' => loc.v2AndroidAutoConnecting,
    'v2AndroidAutoBlackScreenHint' => loc.v2AndroidAutoBlackScreenHint,
    'v2AndroidAutoDragHandle' => loc.v2AndroidAutoDragHandle,
    'v2AndroidAutoReattach' => loc.v2AndroidAutoReattach,
    'v2AndroidAutoStateAvailable' => loc.v2AndroidAutoStateAvailable,
    'v2AndroidAutoStateBound' => loc.v2AndroidAutoStateBound,
    'v2AndroidAutoStateAttached' => loc.v2AndroidAutoStateAttached,
    'v2AndroidAutoErrorUnreachable' => loc.v2AndroidAutoErrorUnreachable,
    'v2AndroidAutoErrorRenderer' => loc.v2AndroidAutoErrorRenderer,
    'v2AndroidAutoErrorBuffer' => loc.v2AndroidAutoErrorBuffer,
    'v2AndroidAutoErrorGeneric' => loc.v2AndroidAutoErrorGeneric,
    _ => throw ArgumentError.value(key, 'key', 'unknown Android Auto key'),
  };
}
