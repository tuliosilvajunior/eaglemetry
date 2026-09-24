import 'dart:async';

import 'package:flutter/material.dart';

import '../core/android_auto_api.dart';
import '../core/projection_touch_api.dart';
import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import '../widgets/projection_touch_surface.dart';

/// Android Auto destination in the v2 shell.
///
/// Renders the live Android Auto video from the head unit's OEM stack into a
/// `Texture` card, and forwards every touch on that texture to the phone
///
/// **One host at a time (R1).** The OEM renderer is a process-wide singleton,
/// so this screen may hold the main surface only while the Android Auto tab is the
/// selected destination *and* the app is resumed. The shell passes [isActive];
/// the screen observes the app lifecycle itself. A mounted-but-hidden screen
/// must never keep the renderer (R1), and this lifecycle path is a backstop,
/// not the mechanism — the ordering guarantee lives in
/// `MainActivity.onPause()` (R4).
class AndroidAutoV2Screen extends StatefulWidget {
  const AndroidAutoV2Screen({
    required this.title,
    required this.isActive,
    this.androidAutoApi,
    this.touchApi,
    this.surfaceOnly = false,
    super.key,
  });

  final String title;

  /// True while the Android Auto tab is the selected destination.
  ///
  /// `AppShellV2` uses an `IndexedStack`, which keeps every visited screen
  /// mounted. A mounted-but-hidden screen must not hold the OEM renderer (R1),
  /// and it cannot detect its own hiding — so the shell tells it.
  final bool isActive;

  final AndroidAutoApi? androidAutoApi;

  /// Injected for tests. The surface builds its own when this is null.
  final ProjectionTouchApi? touchApi;

  /// Shows only the complete video card, without the debug status column.
  final bool surfaceOnly;

  @override
  State<AndroidAutoV2Screen> createState() => _AndroidAutoV2ScreenState();
}

class _AndroidAutoV2ScreenState extends State<AndroidAutoV2Screen>
    with WidgetsBindingObserver {
  late final AndroidAutoApi _api = widget.androidAutoApi ?? AndroidAutoApi();

  AndroidAutoStatus _status = AndroidAutoStatus.empty;

  /// What we asked the native host to do last, so a repeated trigger (tab
  /// rebuild, lifecycle event) does not re-issue the same request.
  bool _requested = false;

  StreamSubscription<AndroidAutoStatus>? _statusSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusSub = _api.statusStream().listen(
      (status) {
        if (mounted) setState(() => _status = status);
      },
      // The stream can die with the host; the seeded status and the method
      // replies still carry truth, so do not treat a dead stream as an error.
      onError: (Object _) {},
    );
    // Seed the first frame instead of showing `empty` until the first event.
    _api.getStatus().then((status) {
      if (mounted) setState(() => _status = status);
    });
    _syncActivation();
  }

  @override
  void didUpdateWidget(AndroidAutoV2Screen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) _syncActivation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _syncActivation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Shell teardown: hand the renderer back. Cannot await in dispose.
    unawaited(_api.deactivate());
    _statusSub?.cancel();
    super.dispose();
  }

  /// Wanted while the tab is selected *and* the app is not backgrounded.
  ///
  /// Anything other than `resumed` counts as inactive — including `inactive`,
  /// which a transient dialog triggers. That costs a detach/attach cycle, the
  /// correct trade against R4.
  ///
  /// A **null** lifecycle means "no information yet", not "backgrounded", and
  /// is treated as resumed. `SchedulerBinding._lifecycleState` starts null and
  /// is only written by `handleAppLifecycleStateChanged`, which `flutter_test`
  /// never dispatches — reading null as inactive made this screen inert in
  /// every widget test. On Android the value is populated from
  /// `initialLifecycleState` long before this screen can mount.
  ///
  /// Safe because Dart does not own the attach decision: `activate()` only
  /// sets `dartActive`, and the native coordinator independently requires
  /// `activityResumed`, driven by `MainActivity.onResume`/`onPause`. A wrong
  /// guess here cannot attach while the activity is paused (R4).
  void _syncActivation() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final foreground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    final wanted = widget.isActive && foreground;
    if (wanted == _requested) return;
    _requested = wanted;
    (wanted ? _api.activate() : _api.deactivate()).then((status) {
      if (mounted) setState(() => _status = status);
    });
  }

  Future<void> _refresh() async {
    final status = await _api.refresh();
    if (mounted) setState(() => _status = status);
  }

  /// Exactly four message states, in priority order (four message states, in priority order). Rendering is deliberately *not* a success message: we
  /// cannot detect whether frames are arriving, so the black-screen hint is
  /// the honest caption while attached.
  ///
  /// Rendering outranks a reported error. `AndroidAutoApi` keeps the last error
  /// until a call succeeds, so a transient `DETACH_FAILED` from an ordinary
  /// tab switch would otherwise caption a picture that is plainly working.
  String? _message(AppLocalizations loc, AndroidAutoStatus status) {
    if (!status.available) return loc.v2AndroidAutoUnavailable;
    if (status.canRender) return null;
    if (status.lastError != null) {
      return _errorMessage(loc, status.lastError!);
    }
    return loc.v2AndroidAutoConnecting;
  }

  String _errorMessage(AppLocalizations loc, String code) => switch (code) {
    'BIND_FAILED' ||
    'SERVICE_UNAVAILABLE' ||
    'BINDING_DIED' ||
    'NULL_BINDING' => loc.v2AndroidAutoErrorUnreachable,
    'ATTACH_FAILED' ||
    'DETACH_FAILED' ||
    'REMOTE_EXCEPTION' => loc.v2AndroidAutoErrorRenderer,
    'INVALID_BUFFER_SIZE' => loc.v2AndroidAutoErrorBuffer,
    // Any future code is safe by construction: it becomes the generic line,
    // never raw text.
    _ => loc.v2AndroidAutoErrorGeneric,
  };

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final status = _status;
    final message = _message(loc, status);
    if (widget.surfaceOnly) {
      return SizedBox.expand(
        child: _AndroidAutoEdgeToEdgeSurface(
          status: status,
          message: message,
          touchEnabled: _requested,
          touchApi: widget.touchApi,
        ),
      );
    }
    final surface = _AndroidAutoSurfaceCard(
      status: status,
      message: message,
      touchEnabled: _requested,
      touchApi: widget.touchApi,
    );
    return SizedBox.expand(
      child: TwoColumnLayout(
        primary: surface,
        trailing: AppCard(
          title: loc.v2AndroidAutoStatusTitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusRow(
                active: status.available,
                icon: Icons.dns,
                label: loc.v2AndroidAutoStateAvailable,
              ),
              const SizedBox(height: AppSpacing.x3),
              _StatusRow(
                active: status.bound,
                icon: Icons.link,
                label: loc.v2AndroidAutoStateBound,
              ),
              const SizedBox(height: AppSpacing.x3),
              _StatusRow(
                active: status.attached,
                icon: Icons.tv,
                label: loc.v2AndroidAutoStateAttached,
              ),
              const SizedBox(height: AppSpacing.x6),
              Text(loc.v2AndroidAutoBuffer, style: AppText.caption),
              const SizedBox(height: AppSpacing.x2),
              Text(
                '${status.bufferWidth} × ${status.bufferHeight}',
                style: AppText.metricMd,
              ),
              const Spacer(),
              SoftActionTile(
                icon: Icons.refresh,
                label: loc.v2AndroidAutoReattach,
                onPressed: _refresh,
                height: AppSizes.actionRowHeight,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The complete Android Auto video card shared by the debug screen and Now.
class _AndroidAutoSurfaceCard extends StatelessWidget {
  const _AndroidAutoSurfaceCard({
    required this.status,
    required this.message,
    required this.touchEnabled,
    this.touchApi,
  });

  final bool touchEnabled;
  final ProjectionTouchApi? touchApi;

  final AndroidAutoStatus status;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    return AppCard(
      title: loc.v2AndroidAutoTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                // From the buffer geometry, not the widget's: the renderer
                // fills the whole Surface with the whole frame.
                aspectRatio: status.bufferAspect,
                child: ClipRRect(
                  borderRadius: AppRadii.xlRadius,
                  child: ColoredBox(
                    color: colors.inverseSurface,
                    child: status.canRender
                        ? ProjectionTouchSurface(
                            stack: ProjectionStack.androidAuto,
                            textureId: status.textureId!,
                            bufferWidth: status.bufferWidth,
                            bufferHeight: status.bufferHeight,
                            enabled: touchEnabled,
                            touchApi: touchApi,
                          )
                        : Center(
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.x4),
                              child: Text(
                                message ?? loc.v2AndroidAutoConnecting,
                                style: AppText.label.copyWith(
                                  color: colors.onInverseSurfaceMuted,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
          if (status.canRender) ...[
            const SizedBox(height: AppSpacing.x4),
            // Attached does not prove that video frames are arriving.
            Text(
              loc.v2AndroidAutoBlackScreenHint,
              style: AppText.caption,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

/// The Now destination's edge-to-edge Android Auto card.
///
/// When video is available, the texture is the card: there is no header,
/// padding, caption, or aspect-ratio inset around it. The empty/error state
/// remains explicit until the native renderer supplies a texture.
class _AndroidAutoEdgeToEdgeSurface extends StatelessWidget {
  const _AndroidAutoEdgeToEdgeSurface({
    required this.status,
    required this.message,
    required this.touchEnabled,
    this.touchApi,
  });

  final bool touchEnabled;
  final ProjectionTouchApi? touchApi;

  final AndroidAutoStatus status;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    return AppCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: AppRadii.xlRadius,
        child: SizedBox.expand(
          child: ColoredBox(
            color: colors.inverseSurface,
            child: status.canRender
                ? ProjectionTouchSurface(
                    stack: ProjectionStack.androidAuto,
                    textureId: status.textureId!,
                    bufferWidth: status.bufferWidth,
                    bufferHeight: status.bufferHeight,
                    enabled: touchEnabled,
                    touchApi: touchApi,
                  )
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.x4),
                      child: Text(
                        message ?? loc.v2AndroidAutoConnecting,
                        style: AppText.label.copyWith(
                          color: colors.onInverseSurfaceMuted,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// One fact row in the status card: a status-light [StatusBadge] plus a
/// localized label. Green only for the state that really holds; grey is a
/// fact, not a fault.
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.active,
    required this.icon,
    required this.label,
  });

  final bool active;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Row(
      children: [
        StatusBadge(
          icon: icon,
          color: active
              ? AppThemeColors.of(context).energy.gain
              : colors.control,
          iconColor: active ? AppColors.onSelection : colors.inkSubtle,
        ),
        const SizedBox(width: AppSpacing.x3),
        Expanded(
          child: Text(
            label,
            style: AppText.bodyStrong,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
