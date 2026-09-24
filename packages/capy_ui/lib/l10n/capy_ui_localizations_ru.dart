// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'capy_ui_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class CapyUiL10nRu extends CapyUiL10n {
  CapyUiL10nRu([String locale = 'ru']) : super(locale);

  @override
  String get settingsAppearance => 'Оформление';

  @override
  String get settingsAppTheme => 'Тема приложения';

  @override
  String get settingsThemeDesc =>
      'Выберите палитру приложения. Каждая плитка показывает страницу, карточку и её текст.';

  @override
  String get settingsThemeNameLight => 'Светлая';

  @override
  String get settingsThemeNameDark => 'Петроль';

  @override
  String get settingsThemeNameMidnight => 'Полночь';

  @override
  String get settingsThemeNameSepia => 'Сепия';

  @override
  String get settingsThemeNameNordic => 'Нордик';

  @override
  String get settingsThemeNameDaylight => 'Дневной свет';

  @override
  String get settingsThemeNameTokyoNeon => 'Токийский неон';

  @override
  String get settingsThemeNameSunsetDrive => 'Закат';

  @override
  String get settingsThemeNameBubblegum => 'Жвачка';

  @override
  String get settingsThemeReadOnlyLabel => 'Подсказка';

  @override
  String get settingsThemeReadOnlyMessage =>
      'Выбор темы недоступен, пока ввод заблокирован.';

  @override
  String get settingsTogglesTitle => 'Переключатели';

  @override
  String get settingsTogglesDesc =>
      'Переключатели учитывают режим вождения. При блокировке ввода они доступны только для чтения.';

  @override
  String get settingsReduceMotionLabel => 'Уменьшение движения';

  @override
  String get settingsReduceMotionDesc =>
      'Ограничить анимации и переходы для более спокойного интерфейса.';

  @override
  String get settingsTogglesReadOnlyLabel => 'Подсказка';

  @override
  String get settingsTogglesReadOnlyMessage =>
      'Переключатели недоступны, пока ввод заблокирован.';
}
