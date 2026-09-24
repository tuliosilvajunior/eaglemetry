// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'capy_ui_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class CapyUiL10nPt extends CapyUiL10n {
  CapyUiL10nPt([String locale = 'pt']) : super(locale);

  @override
  String get settingsAppearance => 'Aparência';

  @override
  String get settingsAppTheme => 'Tema do app';

  @override
  String get settingsThemeDesc =>
      'Escolha a paleta do app. Cada bloco mostra a página, um cartão e o seu texto.';

  @override
  String get settingsThemeNameLight => 'Claro';

  @override
  String get settingsThemeNameDark => 'Petróleo';

  @override
  String get settingsThemeNameMidnight => 'Meia-noite';

  @override
  String get settingsThemeNameSepia => 'Sépia';

  @override
  String get settingsThemeNameNordic => 'Nórdico';

  @override
  String get settingsThemeNameDaylight => 'Luz do dia';

  @override
  String get settingsThemeNameTokyoNeon => 'Tokyo Neon';

  @override
  String get settingsThemeNameSunsetDrive => 'Pôr do Sol';

  @override
  String get settingsThemeNameBubblegum => 'Chiclete';

  @override
  String get settingsThemeReadOnlyLabel => 'Dica';

  @override
  String get settingsThemeReadOnlyMessage =>
      'A seleção de tema não está disponível enquanto a entrada estiver bloqueada.';

  @override
  String get settingsTogglesTitle => 'Interruptores';

  @override
  String get settingsTogglesDesc =>
      'Interruptores que respeitam o modo de condução. Quando a entrada está bloqueada ficam somente leitura.';

  @override
  String get settingsReduceMotionLabel => 'Reduzir movimento';

  @override
  String get settingsReduceMotionDesc =>
      'Limitar animações e transições para uma interface mais estática.';

  @override
  String get settingsTogglesReadOnlyLabel => 'Dica';

  @override
  String get settingsTogglesReadOnlyMessage =>
      'Os interruptores não estão disponíveis enquanto a entrada estiver bloqueada.';
}
