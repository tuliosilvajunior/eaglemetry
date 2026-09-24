import 'package:flutter/foundation.dart';

class DeveloperToolsGate extends ChangeNotifier {
  DeveloperToolsGate._();

  static final DeveloperToolsGate instance = DeveloperToolsGate._();
  static const unlockTapCount = 8;

  int _tapCount = 0;
  bool _unlocked = false;

  bool get unlocked => _unlocked;
  int get tapCount => _tapCount;

  void registerEasterEggTap() {
    if (_unlocked) return;
    _tapCount++;
    if (_tapCount >= unlockTapCount) {
      _unlocked = true;
      notifyListeners();
    }
  }

  /// Direct control, for the settings menu's developer switch.
  ///
  /// The eight-tap easter egg stays: it is how the switch is *found* on a
  /// build where developer mode has never been on. This is how it is turned
  /// back off, which tapping could never do.
  void setUnlocked(bool unlocked) {
    if (_unlocked == unlocked) return;
    _unlocked = unlocked;
    if (!unlocked) _tapCount = 0;
    notifyListeners();
  }

  @visibleForTesting
  void reset() {
    _tapCount = 0;
    _unlocked = false;
    notifyListeners();
  }
}
