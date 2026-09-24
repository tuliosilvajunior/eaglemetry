import 'package:flutter/widgets.dart';

/// Process-wide gate: the Activity is visible to the user.
///
/// Car polls have nothing to find while the Activity is behind another
/// screen. Every [PollLoop] listens here instead of each screen
/// re-implementing the lifecycle. Null [AppLifecycleState] counts as
/// foreground: tests never dispatch one, and treating null as background
/// would freeze every suite.
///
/// The gate reads **visible**, not **focused**. On Android `inactive` is
/// also a visible state — the notification drawer, a system dialog, and
/// the split screen this head unit offers all take focus without taking
/// the display. A poll stopped there leaves old numbers on a card the
/// reader is still looking at, which is worse than the tick it saved.
/// `hidden` and `paused` are the states in which Android says the app is
/// not on screen, and they are the case this gate exists for: a factory
/// screen in front of Capy Energy.
///
/// A live 60 Hz card may still want to stop on `inactive`. That is the
/// card's own judgement, made in its `didChangeAppLifecycleState`, not a
/// second level here.
class AppForegroundGate with WidgetsBindingObserver {
  AppForegroundGate._();

  static final AppForegroundGate instance = AppForegroundGate._();

  final List<VoidCallback> _listeners = <VoidCallback>[];
  bool _attached = false;

  /// True while the Activity is on screen, or while no lifecycle has been
  /// written yet.
  bool get isForeground {
    final binding = _bindingOrNull();
    if (binding == null) return true;
    return switch (binding.lifecycleState) {
      null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => false,
    };
  }

  void addListener(VoidCallback listener) {
    _listeners.add(listener);
    attachIfPossible();
  }

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  /// Hooks the binding when one exists. Tests may construct a [PollLoop]
  /// before `ensureInitialized`; the next [attachIfPossible] picks it up.
  void attachIfPossible() {
    if (_attached) return;
    final binding = _bindingOrNull();
    if (binding == null) return;
    binding.addObserver(this);
    _attached = true;
  }

  WidgetsBinding? _bindingOrNull() {
    try {
      return WidgetsBinding.instance;
    } on Object {
      return null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }
}
