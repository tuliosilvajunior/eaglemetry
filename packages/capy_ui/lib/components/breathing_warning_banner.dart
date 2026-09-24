import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../capy_ui.dart';

/// Fixed-height warning banner with a responsive text area and breathing icon.
///
/// The caller supplies all visible text and the semantic [color]. The central
/// icon circle keeps that solid color. Two circles behind it start at the same
/// size, then breathe to 2x and 3x with progressively lower opacity.
class BreathingWarningBanner extends StatefulWidget {
  const BreathingWarningBanner({
    required this.icon,
    required this.title,
    required this.message,
    required this.color,
    this.iconColor = AppColors.onSelection,
    this.animate = true,
    this.duration = AppMotion.breathing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;

  /// Semantic color for the solid icon circle and both breathing layers.
  final Color color;
  final Color iconColor;

  /// Set false to keep both breathing layers at their initial size.
  final bool animate;

  /// Duration of one expansion or contraction.
  final Duration duration;

  @override
  State<BreathingWarningBanner> createState() => _BreathingWarningBannerState();
}

class _BreathingWarningBannerState extends State<BreathingWarningBanner>
    with SingleTickerProviderStateMixin {
  static const _firstOpacity = 0.26;
  static const _secondOpacity = 0.12;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_reduceMotion == reduceMotion && _controller.isAnimating) return;
    _reduceMotion = reduceMotion;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(BreathingWarningBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller
        ..stop()
        ..duration = widget.duration;
    }
    if (oldWidget.animate != widget.animate ||
        oldWidget.duration != widget.duration) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (widget.animate && !_reduceMotion) {
      if (!_controller.isAnimating) {
        _controller.repeat(reverse: true);
      }
      return;
    }
    _controller
      ..stop()
      ..value = 0;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return SizedBox(
      width: double.infinity,
      height: AppSizes.warningBannerHeight,
      child: ClipRRect(
        borderRadius: AppRadii.mdRadius,
        child: ColoredBox(
          color: colors.surface,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final leadingWidth = constraints.hasBoundedWidth
                  ? math.min(
                      AppSizes.warningBannerLeading,
                      constraints.maxWidth * 0.3,
                    )
                  : AppSizes.warningBannerLeading;
              return MergeSemantics(
                child: Row(
                  children: [
                    SizedBox(
                      width: leadingWidth,
                      height: AppSizes.warningBannerHeight,
                      child: ExcludeSemantics(child: _breathingIcon()),
                    ),
                    const SizedBox(width: AppSpacing.x1),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: AppSpacing.x4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.title,
                              style: AppText.bodyStrong,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: AppSpacing.x1),
                            Text(
                              widget.message,
                              style: AppText.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _breathingIcon() {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final phase = AppMotion.curve.transform(_controller.value);
          return Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              _pulse(
                key: const ValueKey('breathingWarning.secondPulse'),
                opacityKey: const ValueKey('breathingWarning.secondOpacity'),
                scale: 1 + 2 * phase,
                opacity: _secondOpacity,
              ),
              _pulse(
                key: const ValueKey('breathingWarning.firstPulse'),
                opacityKey: const ValueKey('breathingWarning.firstOpacity'),
                scale: 1 + phase,
                opacity: _firstOpacity,
              ),
              Container(
                key: const ValueKey('breathingWarning.iconCircle'),
                width: AppSizes.warningBannerIconCircle,
                height: AppSizes.warningBannerIconCircle,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  widget.icon,
                  size: AppSizes.iconLg,
                  color: widget.iconColor,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _pulse({
    required Key key,
    required Key opacityKey,
    required double scale,
    required double opacity,
  }) {
    return Transform.scale(
      key: key,
      scale: scale,
      child: Opacity(
        key: opacityKey,
        opacity: opacity,
        child: Container(
          width: AppSizes.warningBannerIconCircle,
          height: AppSizes.warningBannerIconCircle,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
