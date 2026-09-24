import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/l10n/app_localizations.dart';
import 'package:capy_energy/l10n/app_localizations_en.dart';
import 'package:capy_energy/l10n/app_localizations_pt.dart';
import 'package:capy_energy/l10n/app_localizations_ru.dart';

/// Parity guard for the CarPlay keys.
///
/// A key missing from `app_pt.arb` or `app_ru.arb` falls back to English
/// silently at runtime; this test turns that into a red build.
void main() {
  final en = AppLocalizationsEn();
  final pt = AppLocalizationsPt();
  final ru = AppLocalizationsRu();

  const proseKeys = [
    'v2CarplayUnavailable',
    'v2CarplayConnecting',
    'v2CarplayBlackScreenHint',
    'v2CarplayDragHandle',
    'v2CarplayReattach',
    'v2CarplayStateAvailable',
    'v2CarplayStateBound',
    'v2CarplayStateAttached',
    'v2CarplayErrorUnreachable',
    'v2CarplayErrorRenderer',
    'v2CarplayErrorBuffer',
    'v2CarplayErrorGeneric',
  ];

  for (final entry in {'en': en, 'pt': pt, 'ru': ru}.entries) {
    test('${entry.key}: every CarPlay key is present', () {
      final loc = entry.value;
      expect(loc.navCarplay, isNotEmpty);
      expect(loc.v2CarplayTitle, isNotEmpty);
      expect(loc.v2CarplayStatusTitle, isNotEmpty);
      expect(loc.v2CarplayUnavailable, isNotEmpty);
      expect(loc.v2CarplayConnecting, isNotEmpty);
      expect(loc.v2CarplayBlackScreenHint, isNotEmpty);
      expect(loc.v2CarplayDragHandle, isNotEmpty);
      expect(loc.v2CarplayReattach, isNotEmpty);
      expect(loc.v2CarplayBuffer, isNotEmpty);
      expect(loc.v2CarplayStateAvailable, isNotEmpty);
      expect(loc.v2CarplayStateBound, isNotEmpty);
      expect(loc.v2CarplayStateAttached, isNotEmpty);
      expect(loc.v2CarplayErrorUnreachable, isNotEmpty);
      expect(loc.v2CarplayErrorRenderer, isNotEmpty);
      expect(loc.v2CarplayErrorBuffer, isNotEmpty);
      expect(loc.v2CarplayErrorGeneric, isNotEmpty);
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
    expect(pt.navCarplay, 'CarPlay');
    expect(ru.navCarplay, 'CarPlay');
    expect(pt.v2CarplayTitle, 'CarPlay');
    expect(ru.v2CarplayTitle, 'CarPlay');
  });
}

String _value(AppLocalizations loc, String key) {
  return switch (key) {
    'v2CarplayUnavailable' => loc.v2CarplayUnavailable,
    'v2CarplayConnecting' => loc.v2CarplayConnecting,
    'v2CarplayBlackScreenHint' => loc.v2CarplayBlackScreenHint,
    'v2CarplayDragHandle' => loc.v2CarplayDragHandle,
    'v2CarplayReattach' => loc.v2CarplayReattach,
    'v2CarplayStateAvailable' => loc.v2CarplayStateAvailable,
    'v2CarplayStateBound' => loc.v2CarplayStateBound,
    'v2CarplayStateAttached' => loc.v2CarplayStateAttached,
    'v2CarplayErrorUnreachable' => loc.v2CarplayErrorUnreachable,
    'v2CarplayErrorRenderer' => loc.v2CarplayErrorRenderer,
    'v2CarplayErrorBuffer' => loc.v2CarplayErrorBuffer,
    'v2CarplayErrorGeneric' => loc.v2CarplayErrorGeneric,
    _ => throw ArgumentError.value(key, 'key', 'unknown CarPlay key'),
  };
}
