import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Selects the app shell used at launch: the new experience (default) or the
/// previous one, kept available as a fallback.
///
/// Whichever shell the user picks is persisted, so the next app launch opens
/// straight into it.
class AppExperienceController extends ChangeNotifier {
  AppExperienceController._();

  static final AppExperienceController instance = AppExperienceController._();

  static const _newUiKey = 'app_shell_new_ui_enabled';

  /// Unchanged on purpose. It used to gate CarPlay alone and now gates both
  /// projection stacks, so keeping the key means a user who already turned the
  /// beta on does not find it off after an update.
  static const _projectionKey = 'carplay_beta_enabled';
  static const _welcomeSeenKey = 'v1_welcome_announcement_seen';
  static const _immersiveKey = 'app_immersive_mode_enabled';
  static const _statusBarHiddenKey = 'app_status_bar_hidden';
  static const _climateBarKey = 'app_climate_bar_enabled';

  bool _newUiEnabled = true;
  bool _projectionEnabled = false;
  bool _welcomeSeen = false;
  bool _immersiveEnabled = true;
  bool _statusBarHidden = false;
  bool _climateBarEnabled = false;

  bool get newUiEnabled => _newUiEnabled;

  /// Whether the projection beta — CarPlay and Android Auto together — is on.
  /// Opt-in: off until the user asks for it.
  ///
  /// One switch for both, because the user is choosing whether the app shows
  /// the phone at all, not which phone they own. Which tab appears is decided
  /// downstream, by which phone the car reports as connected.
  ///
  /// Off means the feature is not merely hidden: the shell never reads either
  /// status, never subscribes, and never probes presence, so neither OEM
  /// service is bound in the first place and no destination has anything to
  /// appear for.
  bool get projectionEnabled => _projectionEnabled;

  /// Whether the user has seen and dismissed the V1.0 experience announcement dialog.
  bool get welcomeSeen => _welcomeSeen;

  /// Whether the app hides the head unit system bars.
  ///
  /// On by default, because the car screen is small and the app owns it. Off
  /// gives the status and navigation bars back, which the user needs when the
  /// head unit has no other way to leave the app.
  bool get immersiveEnabled => _immersiveEnabled;

  /// Whether the status bar stays hidden while the app is not immersive.
  ///
  /// It has no effect when [immersiveEnabled] is on, because immersive mode
  /// hides both bars already. The setting is kept, not cleared, so a user who
  /// goes back to the windowed mode finds the choice they made before.
  bool get statusBarHidden => _statusBarHidden;

  /// Whether the shell shows the climate bar along its bottom edge.
  ///
  /// Off by default. It is a strip nothing on screen can push away — see
  /// `AppJourneyScaffold.staticBar` — so it costs its height on every screen
  /// for as long as it is on, and that is the reader's trade to make rather
  /// than the app's.
  bool get climateBarEnabled => _climateBarEnabled;

  /// Reads the persisted choices.
  ///
  /// `main()` awaits this before `runApp`, so the first frame already knows
  /// which shell to build and there is nothing to notify yet. Listeners are
  /// notified anyway, for the sake of any later call.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _newUiEnabled = prefs.getBool(_newUiKey) ?? true;
    _projectionEnabled = prefs.getBool(_projectionKey) ?? false;
    _welcomeSeen = prefs.getBool(_welcomeSeenKey) ?? false;
    _immersiveEnabled = prefs.getBool(_immersiveKey) ?? true;
    _statusBarHidden = prefs.getBool(_statusBarHiddenKey) ?? false;
    _climateBarEnabled = prefs.getBool(_climateBarKey) ?? false;
    notifyListeners();
  }

  /// Switches shells and remembers the choice.
  ///
  /// The previous shell stays reachable because the new one has not migrated
  /// Trips and Settings yet — placeholders there would otherwise cost access
  /// to real settings, Trace, and backup, which a head unit makes no easier
  /// to recover from.
  Future<void> setNewUiEnabled(bool value) async {
    if (_newUiEnabled == value) return;
    _newUiEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_newUiKey, value);
  }

  /// Turns the projection beta on or off and remembers the choice.
  Future<void> setProjectionEnabled(bool value) async {
    if (_projectionEnabled == value) return;
    _projectionEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_projectionKey, value);
  }

  /// Marks the V1.0 welcome announcement as seen and remembers the choice.
  Future<void> setWelcomeSeen(bool value) async {
    if (_welcomeSeen == value) return;
    _welcomeSeen = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_welcomeSeenKey, value);
  }

  /// Shows or hides the system bars and remembers the choice.
  Future<void> setImmersiveEnabled(bool value) async {
    if (_immersiveEnabled == value) return;
    _immersiveEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_immersiveKey, value);
  }

  /// Hides or shows the status bar of the windowed mode and remembers it.
  Future<void> setStatusBarHidden(bool value) async {
    if (_statusBarHidden == value) return;
    _statusBarHidden = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_statusBarHiddenKey, value);
  }

  /// Shows or hides the climate bar and remembers the choice.
  Future<void> setClimateBarEnabled(bool value) async {
    if (_climateBarEnabled == value) return;
    _climateBarEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_climateBarKey, value);
  }

  @visibleForTesting
  Future<void> reset() async {
    _newUiEnabled = true;
    _projectionEnabled = false;
    _welcomeSeen = false;
    _immersiveEnabled = true;
    _statusBarHidden = false;
    _climateBarEnabled = false;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_newUiKey);
    await prefs.remove(_projectionKey);
    await prefs.remove(_welcomeSeenKey);
    await prefs.remove(_immersiveKey);
    await prefs.remove(_statusBarHiddenKey);
    await prefs.remove(_climateBarKey);
  }
}
