import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// How long a track swap is allowed to take. Long enough to read as a
/// sleeve change, short enough not to hold a glance.
const _trackSwap = Duration(milliseconds: 320);

/// Themed now-playing strip: artwork, title, artist, and volume as a
/// sideways drag across the pill.
///
/// This is not the climate bar. It reads [AppThemeColors] so it follows the
/// chosen theme. Sit it in the climate bar's `centerChild` and it is a themed
/// pill on the bezel, not a second always-dark control.
///
/// Volume bounds come from the caller. A null [onVolumeChanged] disables the
/// drag rather than hiding the fill — the same "do not invent a vehicle
/// limit" convention the climate steppers use.
///
/// At volume zero the fill is a circle the height of the pill. The artwork
/// sits in the centre of that circle; the speaker sits in the matching
/// circle at the other end.
class NowPlayingBar extends StatefulWidget {
  const NowPlayingBar({
    required this.idleLabel,
    required this.volume,
    required this.volumeMax,
    this.title,
    this.artist,
    this.artwork,
    this.isPlaying = false,
    this.volumeMin = 0,
    this.height = AppSizes.climateBarHeight,
    this.onVolumeChanged,
    super.key,
  }) : assert(volumeMin <= volumeMax),
       assert(height >= AppSizes.minTouchTarget);

  /// Shown when [title] is null. A missing track is a real state, not a dash.
  final String idleLabel;

  final String? title;
  final String? artist;

  /// Album art. Null draws the themed placeholder.
  final Widget? artwork;

  final bool isPlaying;

  /// Current volume, in the span the caller read from the vehicle.
  final int volume;
  final int volumeMin;
  final int volumeMax;

  /// Pill height. The automotive floor is [AppSizes.minTouchTarget].
  final double height;

  final ValueChanged<int>? onVolumeChanged;

  @override
  State<NowPlayingBar> createState() => _NowPlayingBarState();
}

class _NowPlayingBarState extends State<NowPlayingBar> {
  bool _dragging = false;
  double _dragRemainder = 0;

  int get _clampedVolume =>
      widget.volume.clamp(widget.volumeMin, widget.volumeMax);

  bool get _volumeEnabled => widget.onVolumeChanged != null;

  String get _trackKey =>
      '${widget.title ?? widget.idleLabel}|${widget.artist ?? ''}';

  void _applyVolume(int next) {
    final clamped = next.clamp(widget.volumeMin, widget.volumeMax);
    if (clamped == widget.volume) return;
    HapticFeedback.selectionClick();
    widget.onVolumeChanged!(clamped);
  }

  void _onDragStart(DragStartDetails _) {
    if (!_volumeEnabled) return;
    _dragRemainder = 0;
    setState(() => _dragging = true);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_volumeEnabled) return;
    _dragRemainder += details.delta.dx;
    final step = AppSizes.nowPlayingVolumeDragStep;
    var delta = 0;
    while (_dragRemainder >= step) {
      _dragRemainder -= step;
      delta += 1;
    }
    while (_dragRemainder <= -step) {
      _dragRemainder += step;
      delta -= 1;
    }
    if (delta != 0) _applyVolume(_clampedVolume + delta);
  }

  void _onDragEnd(DragEndDetails _) {
    if (!_volumeEnabled) return;
    setState(() => _dragging = false);
    _dragRemainder = 0;
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final selected = _dragging;
    final title = widget.title;
    final artist = widget.artist;
    final span = widget.volumeMax - widget.volumeMin;
    final fill = span <= 0 ? 0.0 : (_clampedVolume - widget.volumeMin) / span;
    final cap = widget.height;
    final artSize = widget.height - AppSpacing.x4;

    return Semantics(
      slider: _volumeEnabled,
      enabled: _volumeEnabled,
      label: title ?? widget.idleLabel,
      value: artist,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _volumeEnabled ? _onDragStart : null,
        onHorizontalDragUpdate: _volumeEnabled ? _onDragUpdate : null,
        onHorizontalDragEnd: _volumeEnabled ? _onDragEnd : null,
        child: AnimatedContainer(
          key: const Key('now-playing-bar'),
          duration: AppMotion.fast,
          curve: AppMotion.curve,
          height: widget.height,
          decoration: BoxDecoration(
            color: selected ? colors.selectionFill : colors.control,
            borderRadius: AppRadii.fullRadius,
          ),
          clipBehavior: Clip.antiAlias,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final fillWidth = cap + fill * (constraints.maxWidth - cap);
              return Stack(
                children: [
                  TweenAnimationBuilder<double>(
                    key: const Key('now-playing-volume-fill'),
                    duration: AppMotion.fast,
                    curve: AppMotion.curve,
                    tween: Tween<double>(end: fillWidth),
                    builder: (context, width, _) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: width,
                          height: constraints.maxHeight,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: selected
                                  ? colors.onSelection.withValues(alpha: 0.16)
                                  : colors.ink.withValues(alpha: 0.12),
                              borderRadius: AppRadii.fullRadius,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  Row(
                    children: [
                      SizedBox(
                        width: cap,
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: _trackSwap,
                            switchInCurve: AppMotion.curve,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: _sleeveTransition,
                            child: _Artwork(
                              key: ValueKey<String>(_trackKey),
                              artwork: widget.artwork,
                              selected: selected,
                              isPlaying: widget.isPlaying,
                              size: artSize,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: _trackSwap,
                          switchInCurve: AppMotion.curve,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: _copyTransition,
                          child: _Copy(
                            key: ValueKey<String>(_trackKey),
                            title: title ?? widget.idleLabel,
                            artist: artist,
                            selected: selected,
                            idle: title == null,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: cap,
                        child: Center(
                          child: Icon(
                            key: const Key('now-playing-volume-icon'),
                            _clampedVolume <= widget.volumeMin
                                ? Icons.volume_off
                                : Icons.volume_up,
                            size: AppSizes.iconMd,
                            color: selected
                                ? colors.onSelection
                                : colors.inkMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The incoming sleeve twists in from a quarter-turn; the outgoing one is
/// the same motion reversed. Small on purpose: this is a glance, not a show.
Widget _sleeveTransition(Widget child, Animation<double> animation) {
  final rotate = Tween<double>(begin: -0.04, end: 0).animate(animation);
  final scale = Tween<double>(begin: 0.86, end: 1).animate(animation);
  return FadeTransition(
    opacity: animation,
    child: RotationTransition(
      turns: rotate,
      child: ScaleTransition(scale: scale, child: child),
    ),
  );
}

Widget _copyTransition(Widget child, Animation<double> animation) {
  return FadeTransition(
    opacity: animation,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.28),
        end: Offset.zero,
      ).animate(animation),
      child: child,
    ),
  );
}

class _Artwork extends StatelessWidget {
  const _Artwork({
    required this.artwork,
    required this.selected,
    required this.isPlaying,
    required this.size,
    super.key,
  });

  final Widget? artwork;
  final bool selected;
  final bool isPlaying;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return AnimatedContainer(
      duration: AppMotion.fast,
      curve: AppMotion.curve,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected
            ? colors.onSelection.withValues(alpha: 0.12)
            : colors.surface,
        borderRadius: AppRadii.smRadius,
      ),
      clipBehavior: Clip.antiAlias,
      child:
          artwork ??
          Icon(
            isPlaying ? Icons.music_note : Icons.music_off,
            key: const Key('now-playing-artwork'),
            size: AppSizes.iconMd,
            color: selected ? colors.onSelection : colors.inkMuted,
          ),
    );
  }
}

class _Copy extends StatelessWidget {
  const _Copy({
    required this.title,
    required this.artist,
    required this.selected,
    required this.idle,
    super.key,
  });

  final String title;
  final String? artist;
  final bool selected;
  final bool idle;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final titleColor = selected
        ? colors.onSelection
        : idle
        ? colors.inkMuted
        : colors.ink;
    final artistColor = selected ? colors.onSelection : colors.inkMuted;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.bodyStrong.copyWith(color: titleColor),
        ),
        if (artist != null)
          Text(
            artist!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: artistColor),
          ),
      ],
    );
  }
}
