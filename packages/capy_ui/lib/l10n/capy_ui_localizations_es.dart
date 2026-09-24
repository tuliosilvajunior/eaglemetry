// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'capy_ui_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class CapyUiL10nEs extends CapyUiL10n {
  CapyUiL10nEs([String locale = 'es']) : super(locale);

  @override
  String get settingsAppearance => 'Apariencia';

  @override
  String get settingsAppTheme => 'Tema de la app';

  @override
  String get settingsThemeDesc =>
      'Elija la paleta que la app viste. Cada tarjeta muestra la página, una tarjeta y su texto.';

  @override
  String get settingsThemeNameLight => 'Claro';

  @override
  String get settingsThemeNameDark => 'Petróleo';

  @override
  String get settingsThemeNameMidnight => 'Medianoche';

  @override
  String get settingsThemeNameSepia => 'Sepia';

  @override
  String get settingsThemeNameNordic => 'Nórdico';

  @override
  String get settingsThemeNameDaylight => 'Luz del día';

  @override
  String get settingsThemeNameTokyoNeon => 'Tokyo Neon';

  @override
  String get settingsThemeNameSunsetDrive => 'Atardecer';

  @override
  String get settingsThemeNameBubblegum => 'Chicle';

  @override
  String get settingsThemeReadOnlyLabel => 'Consejo';

  @override
  String get settingsThemeReadOnlyMessage =>
      'La selección de tema no está disponible mientras la entrada está bloqueada.';

  @override
  String get settingsTogglesTitle => 'Interruptores';

  @override
  String get settingsTogglesDesc =>
      'Interruptores que respetan el modo de conducción. Cuando la entrada está bloqueada son de solo lectura.';

  @override
  String get settingsReduceMotionLabel => 'Reducir movimiento';

  @override
  String get settingsReduceMotionDesc =>
      'Limitar animaciones y transiciones para una interfaz más estática.';

  @override
  String get settingsTogglesReadOnlyLabel => 'Consejo';

  @override
  String get settingsTogglesReadOnlyMessage =>
      'Los interruptores no están disponibles mientras la entrada está bloqueada.';
}
