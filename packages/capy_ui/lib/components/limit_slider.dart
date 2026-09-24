import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../capy_ui.dart';

/// Three-zone charge-target slider for Android Automotive.
///
/// The track is one clipped pill. The charged and pending zones are rectangular
/// fills with flat internal seams. The part beyond the target has no fill and
/// keeps only the right-hand portion of the full-pill outline.
///
/// All visible and semantic text comes from the caller. External value changes
/// animate with [AppMotion.base]. Direct manipulation never animates, so the
/// knob stays under the finger or rotary input.
class LimitSlider extends StatefulWidget {
  const LimitSlider({
    required this.value,
    required this.onChanged,
    this.current,
    this.min = 50,
    this.max = 100,
    this.step = 5,
    this.dragStep = 1,
    this.tickInterval = 10,
    this.currentLabel,
    this.currentUnit,
    this.valueLabel,
    this.valueUnit,
    this.caption,
    this.isCharging = false,
    this.chargingPowerKw,
    this.fillColor,
    this.duration = AppMotion.base,
    this.animate = true,
    this.semanticsLabel,
    this.semanticsValue,
    this.increasedValue,
    this.decreasedValue,
    this.onDraggingChanged,
    super.key,
  }) : assert(max > min),
       assert(min >= 0),
       assert(step > 0),
       assert(dragStep > 0),
       assert(tickInterval > 0);

  /// Selected target. The knob sits at this value.
  final double value;
  final ValueChanged<double> onChanged;

  /// Reports when a pointer starts or stops dragging the knob.
  ///
  /// The owner uses it so dependent controls (for example preset tiles) do not
  /// react to intermediate values while the thumb is moving. Fires on drag
  /// start, drag end, and drag cancel, mirroring the internal drag state.
  final ValueChanged<bool>? onDraggingChanged;

  /// Present charge. Null hides the charged zone and its in-track readout.
  final double? current;

  /// Selectable target bounds. The battery fill keeps its full zero-to-[max]
  /// scale, so the default 50% minimum sits at the pill's physical midpoint.
  final double min;
  final double max;

  /// Resolution for taps, keyboard input, and semantics actions.
  final double step;

  /// Finer resolution used only during direct drag input.
  final double dragStep;

  /// Spacing between guides in the unfilled outlined zone.
  final double tickInterval;

  /// Pre-formatted current numeral and its localized unit.
  final String? currentLabel;
  final String? currentUnit;

  /// Pre-formatted target numeral, localized unit, and supporting caption.
  final String? valueLabel;
  final String? valueUnit;
  final String? caption;

  /// Shows live charging flow across the track and a bolt beside current SOC.
  final bool isCharging;

  /// Trusted charging power used only to set the flow cadence.
  ///
  /// Null keeps the slowest cadence. Values above the shared 80 kW chart
  /// ceiling do not make the animation faster.
  final double? chargingPowerKw;

  /// Null takes the theme's gain hue: a charge limit is a gain.
  final Color? fillColor;
  final Duration duration;

  /// Set false to render external changes immediately.
  final bool animate;

  /// Localized semantics strings for touch, keyboard, and rotary input.
  final String? semanticsLabel;
  final String? semanticsValue;
  final String? increasedValue;
  final String? decreasedValue;

  @override
  State<LimitSlider> createState() => _LimitSliderState();
}

class _LimitSliderState extends State<LimitSlider>
    with TickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late double _fromValue;
  late double? _fromCurrent;
  late final AnimationController _chargeFlowController = AnimationController(
    vsync: this,
  );

  /// Fades the drag-only step guides in and out with [AppMotion.fast].
  late final AnimationController _guidesController = AnimationController(
    vsync: this,
    duration: AppMotion.fast,
  );
  late final Animation<double> _guidesOpacity = CurvedAnimation(
    parent: _guidesController,
    curve: AppMotion.curve,
  );
  double? _lastUserValue;
  bool _dragging = false;
  bool _focused = false;
  bool _knobPressed = false;

  @override
  void initState() {
    super.initState();
    _fromValue = widget.value;
    _fromCurrent = widget.current;
    _controller.value = 1;
  }

  @override
  void didUpdateWidget(LimitSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (oldWidget.isCharging != widget.isCharging ||
        oldWidget.chargingPowerKw != widget.chargingPowerKw ||
        oldWidget.animate != widget.animate) {
      _syncChargeFlow();
    }
    if (oldWidget.value == widget.value &&
        oldWidget.current == widget.current) {
      return;
    }

    final currentValue = lerpDouble(
      _fromValue,
      oldWidget.value,
      _controller.value,
    )!;
    final currentCharge = _lerpNullable(
      _fromCurrent,
      oldWidget.current,
      _controller.value,
      0,
    );
    final directManipulation =
        _dragging ||
        (_lastUserValue != null && _sameValue(widget.value, _lastUserValue!));

    if (directManipulation || !widget.animate) {
      _fromValue = widget.value;
      _fromCurrent = widget.current;
      _controller.value = 1;
    } else {
      _fromValue = currentValue;
      _fromCurrent = currentCharge;
      _controller.forward(from: 0);
    }
    _lastUserValue = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncChargeFlow();
  }

  @override
  void dispose() {
    _controller.dispose();
    _chargeFlowController.dispose();
    _guidesController.dispose();
    super.dispose();
  }

  void _syncChargeFlow() {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (!widget.isCharging || !widget.animate || reduceMotion) {
      _chargeFlowController
        ..stop()
        ..value = 0;
      return;
    }
    final period = _chargeFlowPeriod(widget.chargingPowerKw);
    if (_chargeFlowController.isAnimating &&
        _chargeFlowController.duration == period) {
      return;
    }
    _chargeFlowController
      ..duration = period
      ..repeat(period: period);
  }

  /// Converts 0–80 kW to a restrained 2.8–0.95 second traversal.
  ///
  /// The logarithmic response makes low and medium power visibly distinct but
  /// compresses the fast-charge end, where a linear multiplier would become
  /// distracting.
  static Duration _chargeFlowPeriod(double? powerKw) {
    final usablePower = powerKw != null && powerKw.isFinite && powerKw >= 0
        ? powerKw.clamp(0, 80).toDouble()
        : 0.0;
    final normalized = math.log(1 + 9 * usablePower / 80) / math.log(10);
    final milliseconds = 2800 - 1850 * normalized;
    return Duration(milliseconds: milliseconds.round());
  }

  static bool _sameValue(double a, double b) => (a - b).abs() < 0.000001;

  static double? _lerpNullable(
    double? from,
    double? to,
    double t,
    double emptyValue,
  ) {
    if (t >= 1) return to;
    if (from == null && to == null) return null;
    return lerpDouble(from ?? emptyValue, to ?? emptyValue, t);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final shouldAnimate = widget.animate && !reduceMotion;

    return Focus(
      onFocusChange: (focused) {
        if (_focused == focused) return;
        setState(() => _focused = focused);
      },
      onKeyEvent: _handleKey,
      child: Semantics(
        slider: true,
        label: widget.semanticsLabel,
        value: widget.semanticsValue,
        increasedValue: _canIncrease ? widget.increasedValue : null,
        decreasedValue: _canDecrease ? widget.decreasedValue : null,
        onIncrease: _canIncrease ? _increase : null,
        onDecrease: _canDecrease ? _decrease : null,
        excludeSemantics: true,
        child: AnimatedBuilder(
          animation: Listenable.merge([
            _controller,
            _chargeFlowController,
            _guidesController,
          ]),
          builder: (context, _) {
            final t = shouldAnimate ? _controller.value : 1.0;
            final value = lerpDouble(_fromValue, widget.value, t)!;
            final current = _lerpNullable(_fromCurrent, widget.current, t, 0);
            return LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.hasBoundedWidth
                    ? constraints.maxWidth
                    : AppSizes.minTouchTarget * 6;
                final geometry = _LimitGeometry(
                  width: width,
                  min: widget.min,
                  max: widget.max,
                  value: value,
                  current: current,
                );
                return SizedBox(
                  width: width,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: AppSizes.minTouchTarget,
                        child: _TargetReadoutLayout(
                          anchorX: geometry.knobX,
                          child: _TargetReadout(
                            value: widget.valueLabel,
                            unit: widget.valueUnit,
                            caption: widget.caption,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.x2),
                      _track(geometry),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _track(_LimitGeometry geometry) {
    final colors = AppThemeColors.of(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) =>
          _handlePointerDown(event.localPosition, geometry),
      onPointerUp: (_) => _setKnobPressed(false),
      onPointerCancel: (_) => _setKnobPressed(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) =>
            _emitPosition(details.localPosition.dx, geometry),
        onHorizontalDragStart: (details) {
          _setDragging(true);
          _controller.stop();
          _emitPosition(
            details.localPosition.dx,
            geometry,
            step: widget.dragStep,
          );
        },
        onHorizontalDragUpdate: (details) => _emitPosition(
          details.localPosition.dx,
          geometry,
          step: widget.dragStep,
        ),
        onHorizontalDragEnd: (_) => _setDragging(false),
        onHorizontalDragCancel: () => _setDragging(false),
        child: SizedBox(
          height: AppSizes.limitSliderHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _LimitTrackPainter(
                    geometry: geometry,
                    fillColor:
                        widget.fillColor ??
                        AppThemeColors.of(context).energy.gain,
                    flowColor: AppThemeColors.of(context).energy.gainSoft,
                    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                    tickInterval: widget.tickInterval,
                    tickOpacity: _guidesOpacity.value,
                    focused: _focused,
                    chargeFlowProgress:
                        widget.isCharging && widget.animate && !reduceMotion
                        ? AppMotion.curve.transform(_chargeFlowController.value)
                        : null,
                    trackColor: colors.track,
                    guideColor: colors.chartNowMarker,
                    dividerColor: colors.divider,
                    focusColor: AppThemeColors.of(context).energy.focus,
                  ),
                ),
              ),
              if (widget.current != null && widget.currentLabel != null)
                _currentReadout(geometry),
              Positioned(
                left: geometry.knobX - AppSizes.minTouchTarget / 2,
                top: (AppSizes.limitSliderHeight - AppSizes.minTouchTarget) / 2,
                width: AppSizes.minTouchTarget,
                height: AppSizes.minTouchTarget,
                child: Center(
                  key: const ValueKey('limitSlider.knobHitTarget'),
                  child: AnimatedScale(
                    key: const ValueKey('limitSlider.knobScale'),
                    scale: _knobPressed ? AppSizes.limitSliderPressedScale : 1,
                    duration: reduceMotion ? Duration.zero : AppMotion.fast,
                    curve: AppMotion.curve,
                    child: Container(
                      key: const ValueKey('limitSlider.knob'),
                      width: AppSizes.limitSliderKnob,
                      height: AppSizes.limitSliderKnob,
                      decoration: BoxDecoration(
                        color: colors.selectionFill,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handlePointerDown(Offset position, _LimitGeometry geometry) {
    final knobCenter = Offset(geometry.knobX, AppSizes.limitSliderHeight / 2);
    final delta = position - knobCenter;
    final hitRadius = AppSizes.minTouchTarget / 2;
    _setKnobPressed(delta.dx.abs() <= hitRadius && delta.dy.abs() <= hitRadius);
  }

  void _setKnobPressed(bool pressed) {
    if (_knobPressed == pressed) return;
    setState(() => _knobPressed = pressed);
  }

  void _setDragging(bool dragging) {
    if (_dragging == dragging) return;
    setState(() => _dragging = dragging);
    widget.onDraggingChanged?.call(dragging);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      _guidesController.value = dragging ? 1 : 0;
    } else if (dragging) {
      _guidesController.forward();
    } else {
      _guidesController.reverse();
    }
  }

  Widget _currentReadout(_LimitGeometry geometry) {
    final label = widget.currentLabel!;
    final unit = widget.currentUnit;
    final metricWidth = _metricWidth(label, unit);
    final labelWidth = AppSizes.iconMd + AppSpacing.x2 + metricWidth;
    final insideLeft = AppSpacing.x6;
    final fitsInside =
        geometry.currentX >= insideLeft + labelWidth + AppSpacing.x6;
    final outsideLeft = (geometry.currentX + AppSpacing.x3)
        .clamp(
          AppSpacing.x3,
          math.max(AppSpacing.x3, geometry.width - labelWidth - AppSpacing.x3),
        )
        .toDouble();

    return Positioned(
      key: const ValueKey('limitSlider.currentReadout'),
      left: fitsInside ? insideLeft : outsideLeft,
      top: 0,
      height: AppSizes.limitSliderHeight,
      child: Center(
        child: _ChargingSocReadout(
          charging: widget.isCharging,
          value: label,
          unit: unit,
        ),
      ),
    );
  }

  static double _metricWidth(String value, String? unit) {
    double widthOf(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      return painter.width;
    }

    return widthOf(value, AppText.metricMd) +
        (unit == null ? 0 : AppSpacing.x1 + widthOf(unit, AppText.unitMd));
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_canIncrease) _increase();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_canDecrease) _decrease();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool get _canIncrease => widget.value < widget.max;
  bool get _canDecrease => widget.value > widget.min;

  void _increase() => _emit(widget.value + widget.step);
  void _decrease() => _emit(widget.value - widget.step);

  void _emitPosition(double dx, _LimitGeometry geometry, {double? step}) {
    _emit(geometry.valueForControlPosition(dx), step: step);
  }

  void _emit(double raw, {double? step}) {
    final value = _snap(raw, step ?? widget.step);
    _lastUserValue = value;
    widget.onChanged(value);
  }

  double _snap(double raw, double step) {
    final clamped = raw.clamp(widget.min, widget.max);
    if (clamped <= widget.min + step / 2) return widget.min;
    if (clamped >= widget.max - step / 2) return widget.max;
    final steps = ((clamped - widget.min) / step).round();
    return (widget.min + steps * step).clamp(widget.min, widget.max);
  }
}

@immutable
class _LimitGeometry {
  const _LimitGeometry({
    required this.width,
    required this.min,
    required this.max,
    required this.value,
    required this.current,
  });

  final double width;
  final double min;
  final double max;
  final double value;
  final double? current;

  double fraction(double input) => (input / max).clamp(0.0, 1.0);

  double get targetX => value >= max ? width : positionForControl(value);
  double get currentX => current == null ? 0 : fraction(current!) * width;

  /// Keeps the visual control inside the pill at both range extremes.
  ///
  /// Zone boundaries still use [targetX], so 100% fills the complete track.
  /// Only the knob and its readout move to the centre of the end cap.
  double get knobX => positionForControl(value);

  double positionForControl(double input) {
    final endCapCenter = math.min(AppSizes.limitSliderHeight / 2, width / 2);
    final start = math.max(endCapCenter, fraction(min) * width);
    final end = width - endCapCenter;
    if (end <= start) return width / 2;
    final controlFraction = ((input - min) / (max - min)).clamp(0.0, 1.0);
    return start + controlFraction * (end - start);
  }

  double valueForControlPosition(double dx) {
    final start = positionForControl(min);
    final end = positionForControl(max);
    if (end <= start) return min;
    final controlFraction = ((dx - start) / (end - start)).clamp(0.0, 1.0);
    return min + controlFraction * (max - min);
  }

  RRect get track => RRect.fromRectAndRadius(
    Rect.fromLTWH(0, 0, width, AppSizes.limitSliderHeight),
    const Radius.circular(AppSizes.limitSliderHeight / 2),
  );
}

class _LimitTrackPainter extends CustomPainter {
  const _LimitTrackPainter({
    required this.geometry,
    required this.fillColor,
    required this.flowColor,
    required this.backgroundColor,
    required this.tickInterval,
    required this.tickOpacity,
    required this.focused,
    required this.chargeFlowProgress,
    required this.trackColor,
    required this.guideColor,
    required this.dividerColor,
    required this.focusColor,
  });

  final _LimitGeometry geometry;
  final Color fillColor;

  /// The chevrons that run along the fill while charging. A paler step of the
  /// same hue, never a second one.
  final Color flowColor;
  final Color backgroundColor;
  final double tickInterval;

  /// 0–1 opacity for the drag-only step guides; 0 hides them.
  final double tickOpacity;
  final bool focused;
  final double? chargeFlowProgress;
  final Color trackColor;
  final Color guideColor;
  final Color dividerColor;
  final Color focusColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = geometry.track.outerRect;
    canvas.save();
    canvas.clipRRect(geometry.track);

    final currentX = geometry.currentX;
    final targetX = geometry.targetX;
    if (geometry.current != null && currentX > 0) {
      canvas.drawRect(
        Rect.fromLTRB(rect.left, rect.top, currentX, rect.bottom),
        Paint()..color = fillColor,
      );
      final flow = chargeFlowProgress;
      if (flow != null) {
        canvas.save();
        canvas.clipRect(
          Rect.fromLTRB(rect.left, rect.top, currentX, rect.bottom),
        );
        _paintChargeFlow(
          canvas,
          Rect.fromLTRB(rect.left, rect.top, currentX, rect.bottom),
          flow,
        );
        canvas.restore();
      }
    }
    final pendingStart = geometry.current == null ? rect.left : currentX;
    if (targetX > pendingStart) {
      canvas.drawRect(
        Rect.fromLTRB(pendingStart, rect.top, targetX, rect.bottom),
        Paint()..color = trackColor,
      );
    }
    if (geometry.current != null && targetX < currentX) {
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(targetX, rect.center.dy),
          width: AppSizes.limitSliderTargetMarker,
          height: rect.height,
        ),
        Paint()..color = backgroundColor,
      );
    }

    canvas.restore();

    final beyondStart = geometry.current == null
        ? targetX
        : math.max(targetX, currentX);
    if (beyondStart < rect.right) {
      canvas.save();
      canvas.clipRRect(geometry.track);
      if (tickOpacity > 0) {
        final firstTick = (geometry.min / tickInterval).ceil() * tickInterval;
        for (
          var tick = firstTick;
          tick <= geometry.max + 0.000001;
          tick += tickInterval
        ) {
          final tickX = geometry.positionForControl(tick);
          if (tickX <= beyondStart) continue;
          final tickRect = Rect.fromCenter(
            center: Offset(tickX, rect.center.dy),
            width: AppSizes.limitSliderTickWidth,
            height: AppSizes.limitSliderTickHeight,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              tickRect,
              const Radius.circular(AppSizes.limitSliderTickWidth / 2),
            ),
            Paint()..color = guideColor.withValues(alpha: tickOpacity),
          );
        }
      }
      canvas.restore();

      canvas.save();
      canvas.clipRect(
        Rect.fromLTRB(beyondStart, rect.top, rect.right, rect.bottom),
      );
      canvas.drawRRect(
        geometry.track,
        Paint()
          ..color = dividerColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = AppSizes.limitSliderOutline,
      );
      canvas.restore();
    }

    if (focused) {
      canvas.drawRRect(
        geometry.track.deflate(AppSizes.limitSliderOutline),
        Paint()
          ..color = focusColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = AppSizes.limitSliderOutline,
      );
    }
  }

  void _paintChargeFlow(Canvas canvas, Rect rect, double progress) {
    const waveSpacing = AppSpacing.x4;
    const travelPadding = AppSpacing.x8;
    final frontX =
        rect.left - travelPadding + progress * (rect.width + travelPadding * 2);
    for (var index = 0; index < 3; index++) {
      final x = frontX - index * waveSpacing;
      final path = Path()
        ..moveTo(x - AppSpacing.x2, rect.top - AppSpacing.x1)
        ..quadraticBezierTo(
          x + AppSpacing.x3,
          rect.center.dy,
          x - AppSpacing.x2,
          rect.bottom + AppSpacing.x1,
        );
      canvas.drawPath(
        path,
        Paint()
          ..color = flowColor.withValues(alpha: 0.82 - index * 0.22)
          ..style = PaintingStyle.stroke
          ..strokeWidth = AppSpacing.x1
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_LimitTrackPainter old) =>
      old.geometry.width != geometry.width ||
      old.geometry.value != geometry.value ||
      old.geometry.current != geometry.current ||
      old.geometry.min != geometry.min ||
      old.geometry.max != geometry.max ||
      old.fillColor != fillColor ||
      old.flowColor != flowColor ||
      old.backgroundColor != backgroundColor ||
      old.tickInterval != tickInterval ||
      old.tickOpacity != tickOpacity ||
      old.focused != focused ||
      old.chargeFlowProgress != chargeFlowProgress ||
      old.trackColor != trackColor ||
      old.guideColor != guideColor ||
      old.dividerColor != dividerColor ||
      old.focusColor != focusColor;
}

class _ChargingSocReadout extends StatelessWidget {
  const _ChargingSocReadout({
    required this.charging,
    required this.value,
    required this.unit,
  });

  final bool charging;
  final String value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final iconSpace = AppSizes.iconMd + AppSpacing.x2;
    return TweenAnimationBuilder<double>(
      key: const ValueKey('limitSlider.chargingTransition'),
      tween: Tween(end: charging ? 1 : 0),
      duration: reduceMotion ? Duration.zero : AppMotion.base,
      curve: AppMotion.curve,
      builder: (context, progress, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            key: const ValueKey('limitSlider.chargingIconSpace'),
            width: iconSpace * progress,
            height: AppSizes.iconMd,
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: iconSpace,
              maxWidth: iconSpace,
              child: progress <= 0
                  ? const SizedBox.shrink()
                  : Transform.translate(
                      offset: Offset(iconSpace * (1 - progress), 0),
                      child: Opacity(
                        opacity: progress,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Icon(
                            Icons.bolt,
                            key: ValueKey('limitSlider.chargingIcon'),
                            size: AppSizes.iconMd,
                            color: colors.ink,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          MetricValue(value: value, unit: unit, size: MetricSize.md),
        ],
      ),
    );
  }
}

class _TargetReadout extends StatelessWidget {
  const _TargetReadout({this.value, this.unit, this.caption});

  final String? value;
  final String? unit;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    if (value == null && caption == null) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('limitSlider.targetReadout'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (value != null)
          MetricValue(value: value!, unit: unit, size: MetricSize.md),
        if (value != null && caption != null)
          const SizedBox(height: AppSpacing.x1),
        if (caption != null)
          Flexible(
            child: Text(
              caption!,
              style: AppText.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

class _TargetReadoutLayout extends StatelessWidget {
  const _TargetReadoutLayout({required this.anchorX, required this.child});

  final double anchorX;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomSingleChildLayout(
      delegate: _TargetReadoutDelegate(anchorX),
      child: child,
    );
  }
}

class _TargetReadoutDelegate extends SingleChildLayoutDelegate {
  const _TargetReadoutDelegate(this.anchorX);

  final double anchorX;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = (anchorX - childSize.width / 2)
        .clamp(0.0, math.max(0.0, size.width - childSize.width))
        .toDouble();
    return Offset(left, math.max(0.0, size.height - childSize.height));
  }

  @override
  bool shouldRelayout(_TargetReadoutDelegate oldDelegate) =>
      oldDelegate.anchorX != anchorX;
}
