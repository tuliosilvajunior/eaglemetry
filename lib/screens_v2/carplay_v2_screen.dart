import 'dart:async';

import 'package:flutter/material.dart';

import '../core/carplay_api.dart';
import '../core/projection_touch_api.dart';
import '../l10n/app_localizations.dart';
import 'package:capy_ui/capy_ui.dart';
import '../widgets/projection_touch_surface.dart';

/// CarPlay destination in the v2 shell.
///
/// Renders the live CarPlay video from the head unit's OEM stack into a
/// `Texture` card, and forwards every touch on that texture to the phone
///
/// **One host at a time (R1).** The OEM renderer is a process-wide singleton,
/// so this screen may hold the main surface only while the CarPlay tab is the
/// selected destination *and* the app is resumed. The shell passes [isActive];
/// the screen observes the app lifecycle itself. A mounted-but-hidden screen
/// must never keep the renderer (R1), and this lifecycle path is a backstop,
/// not the mechanism — the ordering guarantee lives in
/// `MainActivity.onPause()` (R4).
class CarplayV2Screen extends StatefulWidget {
  const CarplayV2Screen({
    required this.title,
    required this.isActive,
    this.carplayApi,
    this.touchApi,
    this.surfaceOnly = false,
    super.key,
  });

  final String title;

  /// True while the CarPlay tab is the selected destination.
  ///
  /// `AppShellV2` uses an `IndexedStack`, which keeps every visited screen
  /// mounted. A mounted-but-hidden screen must not hold the OEM renderer (R1),
  /// and it cannot detect its own hiding — so the shell tells it.
  final bool isActive;

  final CarplayApi? carplayApi;

  /// Injected for tests. The surface builds its own when this is null.
  final ProjectionTouchApi? touchApi;

  /// Shows only the complete video card, without the debug status column.
  final bool surfaceOnly;

  @override
  State<CarplayV2Screen> createState() => _CarplayV2ScreenState();
}

class _CarplayV2ScreenState extends State<CarplayV2Screen>
    with WidgetsBindingObserver {
  late final CarplayApi _api = widget.carplayApi ?? CarplayApi();

  CarplayStatus _status = CarplayStatus.empty;

  /// What we asked the native host to do last, so a repeated trigger (tab
  /// rebuild, lifecycle event) does not re-issue the same request.
  bool _requested = false;

  StreamSubscription<CarplayStatus>? _statusSub;

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
  void didUpdateWidget(CarplayV2Screen oldWidget) {
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

  /// Exactly four message states, in priority order (`dart-flutter-ui.md`
  /// §3.4). State 4 (rendering) is deliberately *not* a success message: we
  /// cannot detect whether frames are arriving, so the black-screen hint is
  /// the honest caption while attached.
  ///
  /// Rendering outranks a reported error. `CarplayApi` keeps the last error
  /// until a call succeeds, so a transient `DETACH_FAILED` from an ordinary
  /// tab switch would otherwise caption a picture that is plainly working.
  String? _message(AppLocalizations loc, CarplayStatus status) {
    if (!status.available) return loc.v2CarplayUnavailable;
    if (status.canRender) return null;
    if (status.lastError != null) {
      return _errorMessage(loc, status.lastError!);
    }
    return loc.v2CarplayConnecting;
  }

  String _errorMessage(AppLocalizations loc, String code) => switch (code) {
    'BIND_FAILED' ||
    'SERVICE_UNAVAILABLE' ||
    'BINDING_DIED' ||
    'NULL_BINDING' => loc.v2CarplayErrorUnreachable,
    'ATTACH_FAILED' ||
    'DETACH_FAILED' ||
    'REMOTE_EXCEPTION' => loc.v2CarplayErrorRenderer,
    'INVALID_BUFFER_SIZE' => loc.v2CarplayErrorBuffer,
    // Any future code is safe by construction: it becomes the generic line,
    // never raw text.
    _ => loc.v2CarplayErrorGeneric,
  };

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final status = _status;
    final message = _message(loc, status);
    if (widget.surfaceOnly) {
      return SizedBox.expand(
        child: _CarplayEdgeToEdgeSurface(
          status: status,
          message: message,
          touchEnabled: _requested,
          touchApi: widget.touchApi,
        ),
      );
    }
    final surface = _CarplaySurfaceCard(
      status: status,
      message: message,
      touchEnabled: _requested,
      touchApi: widget.touchApi,
    );
    return SizedBox.expand(
      child: TwoColumnLayout(
        primary: surface,
        trailing: AppCard(
          title: loc.v2CarplayStatusTitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusRow(
                active: status.available,
                icon: Icons.dns,
                label: loc.v2CarplayStateAvailable,
              ),
              const SizedBox(height: AppSpacing.x3),
              _StatusRow(
                active: status.bound,
                icon: Icons.link,
                label: loc.v2CarplayStateBound,
              ),
              const SizedBox(height: AppSpacing.x3),
              _StatusRow(
                active: status.attached,
                icon: Icons.tv,
                label: loc.v2CarplayStateAttached,
              ),
              const SizedBox(height: AppSpacing.x6),
              Text(loc.v2CarplayBuffer, style: AppText.caption),
              const SizedBox(height: AppSpacing.x2),
              Text(
                '${status.bufferWidth} × ${status.bufferHeight}',
                style: AppText.metricMd,
              ),
              const Spacer(),
              SoftActionTile(
                icon: Icons.refresh,
                label: loc.v2CarplayReattach,
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

/// The complete CarPlay video card shared by the debug screen and Now.
class _CarplaySurfaceCard extends StatelessWidget {
  const _CarplaySurfaceCard({
    required this.status,
    required this.message,
    required this.touchEnabled,
    this.touchApi,
  });

  final CarplayStatus status;
  final String? message;
  final bool touchEnabled;
  final ProjectionTouchApi? touchApi;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final colors = AppThemeColors.of(context);
    return AppCard(
      title: loc.v2CarplayTitle,
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
                            stack: ProjectionStack.carplay,
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
                                message ?? loc.v2CarplayConnecting,
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
              loc.v2CarplayBlackScreenHint,
              style: AppText.caption,
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}

/// The Now destination's edge-to-edge CarPlay card.
///
/// When video is available, the texture is the card: there is no header,
/// padding, caption, or aspect-ratio inset around it. The empty/error state
/// remains explicit until the native renderer supplies a texture.
class _CarplayEdgeToEdgeSurface extends StatelessWidget {
  const _CarplayEdgeToEdgeSurface({
    required this.status,
    required this.message,
    required this.touchEnabled,
    this.touchApi,
  });

  final CarplayStatus status;
  final String? message;
  final bool touchEnabled;
  final ProjectionTouchApi? touchApi;

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
                    stack: ProjectionStack.carplay,
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
                        message ?? loc.v2CarplayConnecting,
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
