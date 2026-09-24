import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:capy_ui/capy_ui.dart';

/// The outcome of the last action a settings pane ran.
///
/// One value rather than a message plus a flag, so a pane cannot end up
/// showing yesterday's text under today's severity.
@immutable
class SettingsStatus {
  const SettingsStatus.ok(this.message) : isError = false;
  const SettingsStatus.error(this.message) : isError = true;

  final String message;
  final bool isError;
}

/// Shared behaviour for a pane of the settings menu.
///
/// Every pane runs the same shape of work: clear the last outcome, call the
/// platform, report what came back, and buzz differently for success and
/// failure. [runAction] is that shape, so a pane holds only what is specific
/// to it.
mixin SettingsPaneState<T extends StatefulWidget> on State<T> {
  SettingsStatus? get status => _status;
  SettingsStatus? _status;

  /// Runs [action] with [busy] held true for its duration.
  ///
  /// [describe] turns the result into the line the user reads; [describeError]
  /// does the same for a failure. Both are the caller's, because only the
  /// caller knows which localized string applies.
  ///
  /// Returning null from [describe] leaves the status clear — for an action
  /// the user cancelled, which is not an outcome to announce.
  Future<void> runAction<R>({
    required Future<R> Function() action,
    required String? Function(R result) describe,
    required String Function(Object error) describeError,
    required void Function(bool busy) setBusy,
  }) async {
    setState(() {
      _status = null;
      setBusy(true);
    });
    try {
      final result = await action();
      if (!mounted) return;
      final message = describe(result);
      setState(
        () => _status = message == null ? null : SettingsStatus.ok(message),
      );
      HapticFeedback.mediumImpact();
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = SettingsStatus.error(describeError(error)));
      HapticFeedback.heavyImpact();
    } finally {
      if (mounted) setState(() => setBusy(false));
    }
  }

  void reportOk(String message) {
    if (!mounted) return;
    setState(() => _status = SettingsStatus.ok(message));
    HapticFeedback.mediumImpact();
  }

  void reportError(String message) {
    if (!mounted) return;
    setState(() => _status = SettingsStatus.error(message));
    HapticFeedback.heavyImpact();
  }

  void clearStatus() {
    if (!mounted) return;
    setState(() => _status = null);
  }
}

/// The last action's outcome, under the sections it belongs to.
class SettingsStatusLine extends StatelessWidget {
  const SettingsStatusLine({required this.status, super.key});

  final SettingsStatus? status;

  @override
  Widget build(BuildContext context) {
    final status = this.status;
    if (status == null) return const SizedBox.shrink();
    final colors = AppThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.gridGutter),
      child: Text(
        status.message,
        style: AppText.label.copyWith(
          color: status.isError
              ? AppThemeColors.of(context).energy.critical
              : colors.inkMuted,
        ),
      ),
    );
  }
}

// `SettingsEntry`, `SettingsSections`, and `SettingsRows` were promoted to
// `package:capy_ui/capy_ui.dart` (`settings_blocks.dart`). The panes import
// them from there now so the private copies are deleted per #141.
