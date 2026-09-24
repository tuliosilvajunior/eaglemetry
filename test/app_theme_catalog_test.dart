import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/theme_controller.dart';
import 'package:capy_ui/capy_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every theme in the catalogue has a palette', () {
    for (final id in AppThemeId.values) {
      expect(palettes[id], isNotNull, reason: id.name);
      expect(palettes[id]!.id, id);
    }
  });

  test('a theme carries its palette into the ThemeData', () {
    for (final id in AppThemeId.values) {
      final spec = appThemeSpec(id);
      final theme = AppTheme.forId(id);
      expect(theme.brightness, spec.brightness, reason: id.name);
      expect(
        theme.scaffoldBackgroundColor,
        spec.colors.canvas,
        reason: id.name,
      );
      expect(
        theme.extension<AppThemeColors>(),
        same(spec.colors),
        reason: id.name,
      );
    }
  });

  test('a restrained theme keeps the reference ramp', () {
    // The six restrained themes differ in their neutrals alone, so a chart
    // reads the same in all of them.
    const restrained = [
      AppThemeId.light,
      AppThemeId.dark,
      AppThemeId.midnight,
      AppThemeId.sepia,
      AppThemeId.nordic,
      AppThemeId.daylight,
    ];
    for (final id in restrained) {
      expect(
        appThemeSpec(id).colors.energy,
        same(AppEnergyRamp.standard),
        reason: id.name,
      );
    }
  });

  test('an expressive theme states its own ramp', () {
    const expressive = [
      AppThemeId.tokyoNeon,
      AppThemeId.sunsetDrive,
      AppThemeId.bubblegum,
    ];
    for (final id in expressive) {
      final ramp = appThemeSpec(id).colors.energy;
      expect(ramp, isNot(same(AppEnergyRamp.standard)), reason: id.name);
      // A theme may change the hues. It may not make the two roles hard to
      // tell apart, which is the one thing a driver reads them for.
      expect(ramp.gain, isNot(ramp.draw), reason: id.name);
      final gain = HSLColor.fromColor(ramp.gain);
      final draw = HSLColor.fromColor(ramp.draw);
      final apart = (gain.hue - draw.hue).abs();
      expect(
        math.min(apart, 360 - apart),
        greaterThan(60),
        reason: '${id.name}: the two data hues are too close',
      );
    }
  });

  test('an unknown persisted id is not an error', () {
    expect(appThemeIdFromName(null), isNull);
    expect(appThemeIdFromName('a-theme-that-was-removed'), isNull);
    expect(appThemeIdFromName('sepia'), AppThemeId.sepia);
  });

  test('an install from before the catalogue keeps its brightness', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'light'});
    await ThemeController.instance.load();

    expect(ThemeController.instance.themeId, AppThemeId.light);
    expect(ThemeController.instance.themeMode, ThemeMode.light);
  });

  test('a stored id wins over the older brightness key', () async {
    SharedPreferences.setMockInitialValues({
      'theme_mode': 'light',
      'theme_id': 'midnight',
    });
    await ThemeController.instance.load();

    expect(ThemeController.instance.themeId, AppThemeId.midnight);
    expect(ThemeController.instance.isDark, isTrue);
  });

  test('choosing a theme writes both keys', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ThemeController.instance.load();
    await ThemeController.instance.setThemeId(AppThemeId.sepia);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_id'), 'sepia');
    // The brightness key follows, so a downgrade to a build with no catalogue
    // still opens on a light theme.
    expect(prefs.getString('theme_mode'), 'light');
  });
}
