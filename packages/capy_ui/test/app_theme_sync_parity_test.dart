import 'package:capy_ui/tokens/app_palettes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// The annotation channel carries theme ids by name, and the catalogue draws
/// them. The two sets live in different packages, so nothing but a test keeps
/// them equal.
///
/// This is the class of the 2026-08-15 range-estimate defect: an unknown
/// source name dropped the whole estimate while the mock and the tests
/// passed because they spelled the name themselves. Here the same failure
/// would look like this: a new theme ships in `capy_ui`, the sync set does
/// not follow, and a phone that proposes it is refused by the car — or the
/// reverse, a synced id no build draws.
///
/// The consequence is pinned by the plan's unknown-identifier rule: a side
/// that cannot draw a theme renders the default and keeps the stored value.
/// The drift this test guards against is the set that either side accepts
/// silently narrowing, which would make a *known* theme behave as unknown.
void main() {
  final catalogue = AppThemeId.values.map((id) => id.name).toSet();

  test('every catalogue theme is accepted by the sync', () {
    expect(
      catalogue.difference(kAnnotationAcceptedThemeIds),
      isEmpty,
      reason:
          'A theme the catalogue can draw but the sync refuses can never '
          'reach the other side. Add it to '
          'kAnnotationAcceptedThemeIds in telemetry_core.',
    );
  });

  test('every accepted theme id is in the catalogue', () {
    expect(
      kAnnotationAcceptedThemeIds.difference(catalogue),
      isEmpty,
      reason:
          'A theme id the sync accepts but no build draws will render as the '
          'default forever. Remove it, or the catalogue owns a promise '
          'nothing keeps.',
    );
  });

  test(
    'appThemeCanvasHex produces valid 7-character hex colors for all themes',
    () {
      final hexPattern = RegExp(r'^#[0-9A-F]{6}$');
      for (final id in AppThemeId.values) {
        final hex = appThemeCanvasHex(id);
        expect(
          hexPattern.hasMatch(hex),
          isTrue,
          reason: 'Theme $id produced invalid hex $hex',
        );
      }
    },
  );
}
