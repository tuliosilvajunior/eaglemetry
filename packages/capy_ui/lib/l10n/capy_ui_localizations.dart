import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'capy_ui_localizations_en.dart';
import 'capy_ui_localizations_es.dart';
import 'capy_ui_localizations_pt.dart';
import 'capy_ui_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of CapyUiL10n
/// returned by `CapyUiL10n.of(context)`.
///
/// Applications need to include `CapyUiL10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/capy_ui_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: CapyUiL10n.localizationsDelegates,
///   supportedLocales: CapyUiL10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the CapyUiL10n.supportedLocales
/// property.
abstract class CapyUiL10n {
  CapyUiL10n(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static CapyUiL10n of(BuildContext context) {
    return Localizations.of<CapyUiL10n>(context, CapyUiL10n)!;
  }

  static const LocalizationsDelegate<CapyUiL10n> delegate =
      _CapyUiL10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
    Locale('pt'),
    Locale('ru'),
  ];

  /// No description provided for @settingsAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// No description provided for @settingsAppTheme.
  ///
  /// In en, this message translates to:
  /// **'App theme'**
  String get settingsAppTheme;

  /// No description provided for @settingsThemeDesc.
  ///
  /// In en, this message translates to:
  /// **'Choose the palette the app wears. Each tile shows the page, a card, and its text.'**
  String get settingsThemeDesc;

  /// No description provided for @settingsThemeNameLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsThemeNameLight;

  /// No description provided for @settingsThemeNameDark.
  ///
  /// In en, this message translates to:
  /// **'Petrol'**
  String get settingsThemeNameDark;

  /// No description provided for @settingsThemeNameMidnight.
  ///
  /// In en, this message translates to:
  /// **'Midnight'**
  String get settingsThemeNameMidnight;

  /// No description provided for @settingsThemeNameSepia.
  ///
  /// In en, this message translates to:
  /// **'Sepia'**
  String get settingsThemeNameSepia;

  /// No description provided for @settingsThemeNameNordic.
  ///
  /// In en, this message translates to:
  /// **'Nordic'**
  String get settingsThemeNameNordic;

  /// No description provided for @settingsThemeNameDaylight.
  ///
  /// In en, this message translates to:
  /// **'Daylight'**
  String get settingsThemeNameDaylight;

  /// No description provided for @settingsThemeNameTokyoNeon.
  ///
  /// In en, this message translates to:
  /// **'Tokyo Neon'**
  String get settingsThemeNameTokyoNeon;

  /// No description provided for @settingsThemeNameSunsetDrive.
  ///
  /// In en, this message translates to:
  /// **'Sunset Drive'**
  String get settingsThemeNameSunsetDrive;

  /// No description provided for @settingsThemeNameBubblegum.
  ///
  /// In en, this message translates to:
  /// **'Bubblegum'**
  String get settingsThemeNameBubblegum;

  /// No description provided for @settingsThemeReadOnlyLabel.
  ///
  /// In en, this message translates to:
  /// **'Tip'**
  String get settingsThemeReadOnlyLabel;

  /// No description provided for @settingsThemeReadOnlyMessage.
  ///
  /// In en, this message translates to:
  /// **'Theme selection is unavailable while keyboard input is blocked.'**
  String get settingsThemeReadOnlyMessage;

  /// No description provided for @settingsTogglesTitle.
  ///
  /// In en, this message translates to:
  /// **'Toggles'**
  String get settingsTogglesTitle;

  /// No description provided for @settingsTogglesDesc.
  ///
  /// In en, this message translates to:
  /// **'Switches that respect driving mode. When input is blocked they are read-only.'**
  String get settingsTogglesDesc;

  /// No description provided for @settingsReduceMotionLabel.
  ///
  /// In en, this message translates to:
  /// **'Reduce motion'**
  String get settingsReduceMotionLabel;

  /// No description provided for @settingsReduceMotionDesc.
  ///
  /// In en, this message translates to:
  /// **'Limit animations and transitions for a still interface.'**
  String get settingsReduceMotionDesc;

  /// No description provided for @settingsTogglesReadOnlyLabel.
  ///
  /// In en, this message translates to:
  /// **'Tip'**
  String get settingsTogglesReadOnlyLabel;

  /// No description provided for @settingsTogglesReadOnlyMessage.
  ///
  /// In en, this message translates to:
  /// **'Toggles are unavailable while input is blocked.'**
  String get settingsTogglesReadOnlyMessage;
}

class _CapyUiL10nDelegate extends LocalizationsDelegate<CapyUiL10n> {
  const _CapyUiL10nDelegate();

  @override
  Future<CapyUiL10n> load(Locale locale) {
    return SynchronousFuture<CapyUiL10n>(lookupCapyUiL10n(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es', 'pt', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_CapyUiL10nDelegate old) => false;
}

CapyUiL10n lookupCapyUiL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return CapyUiL10nEn();
    case 'es':
      return CapyUiL10nEs();
    case 'pt':
      return CapyUiL10nPt();
    case 'ru':
      return CapyUiL10nRu();
  }

  throw FlutterError(
    'CapyUiL10n.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
