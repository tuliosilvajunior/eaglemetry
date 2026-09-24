import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:telemetry_core/telemetry_core.dart';
import '../capy_ui.dart';

/// Developer-only harness for the driving-smoothness pill.
///
/// The pill is a fold over a window, so it cannot be judged from a fixture: what
/// it is worth depends entirely on how it moves while the driving changes. This
/// screen drives the shipped [SmoothnessTracker] from a simulated car, or by
/// hand, and shows the power trace beside the pill so a knob position can always
/// be traced back to what the car was doing.
///
/// Run it on its own:
///
/// ```sh
/// flutter run -d chrome -t packages/capy_ui/lib/gallery/smoothness_main.dart
/// ```
///
/// ## What to look for
///
///  * **Steady** parks the knob at the top, at every speed. That is the whole
///    reason the previous reading was replaced: it read a steady 90 km/h as
///    near-worst and a steady 30 km/h as best.
///  * **Aggressive** drops it to the floor and keeps it there, while
///    **Gentle** sits well above neutral. The order is the instrument.
///  * The **tick** leads the knob. Change style mid-run and watch the tick move
///    first, with the knob following over the next thirty seconds. The gap
///    between the two is the whole coaching.
///  * **Manual** is the fastest way to feel it. Hold the power slider still and
///    the knob climbs; saw it back and forth and the knob falls.
///  * The **reference** slider is the one uncalibrated number in the reading.
///    Moving it moves neutral.
class SmoothnessGalleryScreen extends StatefulWidget {
  const SmoothnessGalleryScreen({super.key});

  @override
  State<SmoothnessGalleryScreen> createState() =>
      _SmoothnessGalleryScreenState();
}

enum _Mode {
  simulated('Simulated'),
  manual('Manual');

  const _Mode(this.label);

  final String label;
}

/// How hard the simulated driver drives.
///
/// Only the acceleration and braking rates change. The route — the speeds held
/// and how long for — is identical, so the styles differ in technique alone,
/// which is what the pill claims to measure.
enum _Style {
  steady('Steady', 0, 0),
  gentle('Gentle', 1.0, 1.2),
  normal('Normal', 1.8, 2.0),
  aggressive('Aggressive', 3.2, 3.5),
  stopGo('Stop-go', 2.6, 3.0);

  const _Style(this.label, this.accelMps2, this.decelMps2);

  final String label;
  final double accelMps2;
  final double decelMps2;

  /// Cruise speed and hold time for each leg of the route.
  List<(double, double)> get route => switch (this) {
    _Style.steady => const [(50, 600)],
    _Style.stopGo => const [(30, 4), (40, 5), (25, 3), (35, 4)],
    _ => const [(30, 25), (50, 40), (30, 20), (45, 35), (25, 15)],
  };
}

class _SmoothnessGalleryScreenState extends State<SmoothnessGalleryScreen> {
  /// One simulated step per timer tick, at the tracker's own grid width.
  ///
  /// The clock handed to the tracker is simulated rather than read from
  /// `DateTime.now`, so the harness is deterministic and a widget test can drive
  /// it with `tester.pump`. It advances one grid step per tick, which means the
  /// pill updates once per tick — the shipped cadence exactly.
  static const _tick = Duration(milliseconds: 50);

  SmoothnessTracker _tracker = SmoothnessTracker();
  final ValueNotifier<DrivingSmoothness> _reading = ValueNotifier(
    DrivingSmoothness.unavailable,
  );

  /// The last thirty seconds of drive power, for the trace under the pill.
  final Queue<double> _trace = ListQueue<double>();

  Timer? _timer;
  _Mode _mode = _Mode.simulated;
  _Style _style = _Style.normal;
  bool _running = true;
  double _reference = kSmoothnessReferenceRampKwPerKm;

  /// Manual-mode inputs.
  double _manualSpeedKmh = 50;
  double _manualPowerKw = 6;

  final _Car _car = _Car();
  int _simulatedMillis = 0;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _reading.dispose();
    super.dispose();
  }

  void _restart() {
    _timer?.cancel();
    if (!_running) return;
    _timer = Timer.periodic(_tick, (_) => _step());
  }

  /// Advances the car by one grid step and offers the sample to the tracker.
  void _step() {
    _simulatedMillis += kSmoothnessSampleInterval.inMilliseconds;
    final double speed;
    final double power;
    if (_mode == _Mode.manual) {
      speed = _manualSpeedKmh;
      power = _manualPowerKw;
    } else {
      _car.advance(_style, kSmoothnessSampleInterval);
      speed = _car.speedKmh;
      power = _car.powerKw;
    }

    _tracker.observe(
      nowMillis: _simulatedMillis,
      speedKmh: speed,
      drivePowerKw: power,
    );
    _reading.value = _tracker.readingAt(_simulatedMillis);

    _trace.addLast(power);
    final span =
        kSmoothnessWindow.inMilliseconds ~/
        kSmoothnessSampleInterval.inMilliseconds;
    while (_trace.length > span) {
      _trace.removeFirst();
    }
    // The trace and the numeric rows are the only things that need the frame.
    // The pill is on its own notifier, exactly as the product has it.
    setState(() {});
  }

  /// Replaces the tracker whenever the reference moves.
  ///
  /// The reference is a construction argument rather than a setter, because in
  /// the product it is a constant and a tracker that could be retuned mid-window
  /// would report a ramp scored against two different neutrals. Replacing it
  /// also makes the change visible: the window refills over the next thirty
  /// seconds rather than the knob teleporting.
  void _setReference(double value) {
    setState(() {
      _reference = value;
      _tracker = SmoothnessTracker(reference: value);
      _trace.clear();
      _reading.value = DrivingSmoothness.unavailable;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeColors.of(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.gridGutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Driving smoothness',
                style: AppText.cardTitle.copyWith(color: colors.ink),
              ),
              const SizedBox(height: AppSpacing.x2),
              Text(
                'Technique, not efficiency. Steady reads the same at every '
                'speed; only how the power is changed moves the knob.',
                style: AppText.body.copyWith(color: colors.inkMuted),
              ),
              const SizedBox(height: AppSpacing.gridGutter),
              Wrap(
                spacing: AppSpacing.gridGutter,
                runSpacing: AppSpacing.gridGutter,
                crossAxisAlignment: WrapCrossAlignment.start,
                children: [_pillPanel(colors), _controls(colors)],
              ),
              const SizedBox(height: AppSpacing.gridGutter),
              _tracePanel(colors),
            ],
          ),
        ),
      ),
    );
  }

  /// The pill at review size beside the pill at shipping size.
  ///
  /// Both are the same widget. The large one is for judging the marks; the
  /// small one is the only one that answers whether they are legible on the
  /// car, which is the question that matters.
  Widget _pillPanel(AppThemeColors colors) {
    return AppCard(
      child: SizedBox(
        width: 340,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'the pill',
              style: AppText.caption.copyWith(color: colors.inkMuted),
            ),
            const SizedBox(height: AppSpacing.x3),
            ValueListenableBuilder<DrivingSmoothness>(
              valueListenable: _reading,
              builder: (context, reading, _) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 300,
                    child: SmoothnessLevel(smoothness: reading, width: 64),
                  ),
                  const SizedBox(width: AppSpacing.gridGutter),
                  SizedBox(
                    height: 300,
                    child: SmoothnessLevel(smoothness: reading),
                  ),
                  const SizedBox(width: AppSpacing.gridGutter),
                  Expanded(child: _readings(colors, reading)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readings(AppThemeColors colors, DrivingSmoothness reading) {
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.caption.copyWith(color: colors.inkMuted)),
          Text(value, style: AppText.body.copyWith(color: colors.ink)),
        ],
      ),
    );

    String pos(double? value) =>
        value == null ? '--' : value.toStringAsFixed(2);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('state', reading.state.name),
        row('knob · 30 s', pos(reading.standing)),
        row('tick · 5 s', pos(reading.instant)),
        row(
          'ramp',
          reading.rampKwPerKm == null
              ? '--'
              : '${reading.rampKwPerKm!.toStringAsFixed(0)} kW/km',
        ),
        row('now vs recent', switch (reading.improving) {
          null => '--',
          true => 'improving',
          false => 'worse',
        }),
      ],
    );
  }

  Widget _controls(AppThemeColors colors) {
    return AppCard(
      child: SizedBox(
        width: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'controls',
              style: AppText.caption.copyWith(color: colors.inkMuted),
            ),
            const SizedBox(height: AppSpacing.x3),
            TrackSegmentedControl<_Mode>(
              items: [
                for (final mode in _Mode.values)
                  TabItem(value: mode, label: mode.label),
              ],
              selected: _mode,
              onSelected: (value) => setState(() => _mode = value),
            ),
            const SizedBox(height: AppSpacing.gridGutter),
            if (_mode == _Mode.simulated)
              // Five segments are wider than the card at small text scales, and
              // a segmented control cannot truncate without hiding a choice.
              // Scrolling keeps every style reachable.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: TrackSegmentedControl<_Style>(
                  items: [
                    for (final style in _Style.values)
                      TabItem(value: style, label: style.label),
                  ],
                  selected: _style,
                  onSelected: (value) => setState(() => _style = value),
                ),
              )
            else ...[
              _slider(
                colors,
                'speed',
                '${_manualSpeedKmh.toStringAsFixed(0)} km/h',
                _manualSpeedKmh,
                0,
                120,
                (value) => setState(() => _manualSpeedKmh = value),
              ),
              _slider(
                colors,
                'drive power',
                '${_manualPowerKw.toStringAsFixed(1)} kW',
                _manualPowerKw,
                -40,
                80,
                (value) => setState(() => _manualPowerKw = value),
              ),
            ],
            const SizedBox(height: AppSpacing.gridGutter),
            _slider(
              colors,
              'reference ramp · neutral point',
              '${_reference.toStringAsFixed(0)} kW/km',
              _reference,
              100,
              1200,
              _setReference,
            ),
            Text(
              'The one number in the reading that has never been measured on '
              'the car. It sets where neutral sits.',
              style: AppText.caption.copyWith(color: colors.inkMuted),
            ),
            const SizedBox(height: AppSpacing.gridGutter),
            Row(
              children: [
                TextButton(
                  onPressed: () {
                    setState(() => _running = !_running);
                    _restart();
                  },
                  child: Text(_running ? 'Pause' : 'Run'),
                ),
                const SizedBox(width: AppSpacing.x3),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _tracker.reset();
                      _trace.clear();
                      _car.reset();
                      _reading.value = DrivingSmoothness.unavailable;
                    });
                  },
                  child: const Text('Reset'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider(
    AppThemeColors colors,
    String label,
    String value,
    double current,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // The label truncates and the value never does: the number is the
            // reading, the label is what it is called.
            Flexible(
              child: Text(
                label,
                style: AppText.caption.copyWith(color: colors.inkMuted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppSpacing.x3),
            Text(value, style: AppText.body.copyWith(color: colors.ink)),
          ],
        ),
        Slider(
          value: current.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// The power trace, so a knob position can be read against what the car did.
  Widget _tracePanel(AppThemeColors colors) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'drive power · last 30 s · the window the knob reads',
            style: AppText.caption.copyWith(color: colors.inkMuted),
          ),
          const SizedBox(height: AppSpacing.x3),
          SizedBox(
            height: 140,
            width: double.infinity,
            child: CustomPaint(
              painter: _TracePainter(
                samples: _trace.toList(growable: false),
                line: colors.ink,
                zero: colors.chartGrid,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A car that follows a route at whichever style is selected.
///
/// Deliberately thin: the pill reads power against distance, so the only thing
/// the harness owes it is a plausible power for a plausible speed.
class _Car {
  static const _g = 9.80665;
  static const _mass = 1550.0;
  static const _crr = 0.011;
  static const _cda = 0.72;
  static const _rho = 1.2;
  static const _eta = 0.88;
  static const _regenCapKw = 35.0;

  double speedKmh = 0;
  double powerKw = 0;

  int _leg = 0;
  double _holdSeconds = 0;
  bool _accelerating = true;

  void reset() {
    speedKmh = 0;
    powerKw = 0;
    _leg = 0;
    _holdSeconds = 0;
    _accelerating = true;
  }

  void advance(_Style style, Duration step) {
    final seconds = step.inMilliseconds / 1000;
    final route = style.route;
    final (targetKmh, holdFor) = route[_leg % route.length];

    var accelMps2 = 0.0;
    if (style == _Style.steady) {
      // No route to follow: reach the speed once, then hold it exactly.
      accelMps2 = speedKmh < targetKmh ? 1.0 : 0.0;
      speedKmh = math.min(targetKmh, speedKmh + accelMps2 * seconds * 3.6);
    } else if (_accelerating) {
      accelMps2 = style.accelMps2;
      speedKmh += accelMps2 * seconds * 3.6;
      if (speedKmh >= targetKmh) {
        speedKmh = targetKmh;
        _accelerating = false;
        _holdSeconds = 0;
      }
    } else if (_holdSeconds < holdFor) {
      _holdSeconds += seconds;
    } else {
      accelMps2 = -style.decelMps2;
      speedKmh += accelMps2 * seconds * 3.6;
      if (speedKmh <= 0) {
        speedKmh = 0;
        _accelerating = true;
        _leg++;
      }
    }

    powerKw = _powerFor(speedKmh / 3.6, accelMps2);
  }

  double _powerFor(double v, double a) {
    final road =
        _crr * _mass * _g * v + 0.5 * _rho * _cda * v * v * v + _mass * a * v;
    final kw = road / 1000;
    if (kw >= 0) return kw / _eta;
    // `VCU_DrvPwrAct` quantises to 0.1 kW, and the deadband is sized against
    // that. Rounding here keeps the harness honest about what the tracker sees.
    return -math.min(-kw * _eta, _regenCapKw);
  }
}

class _TracePainter extends CustomPainter {
  const _TracePainter({
    required this.samples,
    required this.line,
    required this.zero,
  });

  final List<double> samples;
  final Color line;
  final Color zero;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;
    var low = samples.reduce(math.min);
    var high = samples.reduce(math.max);
    // A flat trace has no range to scale by, and dividing by it would put the
    // line at an arbitrary height. Give it a symmetric window instead, so
    // steady power draws a straight line through the middle.
    if (high - low < 2) {
      final mid = (high + low) / 2;
      low = mid - 1;
      high = mid + 1;
    }

    double y(double value) =>
        size.height * (1 - (value - low) / (high - low)).clamp(0.0, 1.0);

    if (low <= 0 && high >= 0) {
      canvas.drawLine(
        Offset(0, y(0)),
        Offset(size.width, y(0)),
        Paint()
          ..color = zero
          ..strokeWidth = 1.5,
      );
    }

    final step = size.width / (samples.length - 1);
    final path = Path()..moveTo(0, y(samples.first));
    for (var i = 1; i < samples.length; i++) {
      path.lineTo(i * step, y(samples[i]));
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..color = line,
    );
  }

  @override
  bool shouldRepaint(_TracePainter old) =>
      old.samples != samples || old.line != line || old.zero != zero;
}
