import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:telemetry_core/telemetry_core.dart';
import '../capy_ui.dart';

/// Developer-only harness for the efficiency card.
///
/// The card is a ratio of two integrals, so it cannot be judged from a static
/// fixture: what matters is how it behaves while the driving changes. This
/// screen drives it from a simulated car rather than from a list of plotted
/// values — the harness produces energy and distance per ten-second bucket and
/// then runs `readEfficiency`, which is the same path the real card takes.
/// A shape that only appears when the maths runs is therefore visible here.
///
/// What to look for:
///
///  * Green must mean range earned and grey range lost, on the **cost** line.
///    The demand line under it carries no verdict and must never be coloured.
///    A stop with the climate system running has to read at the clip line, not
///    as a gap.
///  * The band between the lines is the regeneration. Switch to Town and it
///    should thicken; switch to Highway and it should nearly close.
///  * A gap must break both lines. A stroke that spans one is drawing driving
///    that was never measured.
///  * The window control changes how far back each point reaches. Drag it to
///    ten seconds and the cost line should tear itself apart — that is the
///    defect the window exists to fix, and it must be visible here.
///  * The average must not move when the window does. It is the whole fifteen
///    minutes either way, and the table below prints both to prove it.
///  * The average must not chase the last bucket.
///  * The pill runs on its own clock. It must move while the line is still
///    holding its last ten-second step, and it must fall as soon as the
///    throttle goes down — before any bucket closes.
///  * The knob must never jump. It travels, or the reading goes away.
///  * Moving the reference must move the neutral mark's meaning, not the line.
///
/// The copy here is demo text, not product copy — this screen never ships, so
/// it is exempt from the ARB rule that governs real screens.
class EfficiencyGalleryScreen extends StatefulWidget {
  const EfficiencyGalleryScreen({super.key});

  @override
  State<EfficiencyGalleryScreen> createState() =>
      _EfficiencyGalleryScreenState();
}

/// What the simulated car is doing.
enum _Driving {
  town('Town', 'stop-start, frequent regeneration'),
  highway('Highway', 'steady load, high speed'),
  crawl('Traffic', 'barely moving, climate running'),
  descent('Descent', 'net gain for minutes at a time'),
  parked('Parked', 'reporting nothing at all');

  const _Driving(this.label, this.note);

  final String label;
  final String note;
}

class _EfficiencyGalleryScreenState extends State<EfficiencyGalleryScreen> {
  static const _bucket = Duration(seconds: 10);
  static const _windowBuckets = 90;

  /// One bucket per tick. Far faster than the car, so fifteen minutes of
  /// driving can be watched in fifteen seconds.
  static const _tick = Duration(milliseconds: 160);

  /// The pill's clock. Fast enough to show that it does not wait for a bucket.
  static const _pulse = Duration(milliseconds: 40);

  final _car = _SimulatedCar();

  _Driving _driving = _Driving.town;
  double _ceilingWhPerKm = 300;

  /// How far back each point reaches. The product constant is
  /// [kEfficiencyWindow]; here it is a control, because the whole argument for
  /// it is one you have to see move.
  Duration _window = kEfficiencyWindow;

  /// Efficiency the app's range estimate divides by. Null stands for a degraded
  /// `RangeEstimate`, which must empty the pill rather than assume a divisor.
  double? _reference = 6;

  /// Local to the harness. The shipping card reads the host's persisted
  /// controller; this screen must not import the app to review a component.
  EfficiencyUnit _unit = EfficiencyUnit.kmPerKwh;

  bool _running = true;
  Timer? _timer;
  Timer? _pulseTimer;

  @override
  void initState() {
    super.initState();
    _car.fill(_windowBuckets, _Driving.town);
    _seedSmoothness();
    _restart();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseTimer?.cancel();
    _smoothnessNotifier.dispose();
    super.dispose();
  }

  void _restart() {
    _timer?.cancel();
    _pulseTimer?.cancel();
    if (!_running) return;
    _timer = Timer.periodic(_tick, (_) {
      setState(() => _car.advance(_driving));
      _publishSmoothness();
    });
    // No `setState`. The pulse is the pill's clock, and the product deliberately
    // keeps the pill inside its own builder so the bus rate never reaches the
    // line. A harness that rebuilds the whole screen here would measure a
    // smoothness the card does not have, which is the one thing it must not do.
    _pulseTimer = Timer.periodic(_pulse, (_) {
      _car.pulse(_driving);
      _publishSmoothness();
    });
  }

  EfficiencySeries get _series => readEfficiency(_car.buckets, window: _window);

  /// The same fold the product runs, fed from the simulated car.
  ///
  /// The harness must not compute the reading itself: a second implementation
  /// would drift from the shipped one and the screen would then be reviewing
  /// something the car never shows.
  final SmoothnessTracker _tracker = SmoothnessTracker();

  /// Feeds the tracker one sample and republishes when it accepts it.
  ///
  /// The tracker keeps its own 200 ms grid, so calling this on every pulse is
  /// correct — it simply drops what lands between grid points, exactly as the
  /// product does at 60 Hz.
  void _publishSmoothness() {
    // A simulated clock, not the wall clock. Two reasons, and both matter.
    // The harness fast-forwards a car, so wall time does not describe the
    // driving it is showing; and `tester.pump` does not advance `DateTime.now`,
    // so a wall-clock tracker would take one sample and then refuse every
    // sample the widget test fed it.
    //
    // One pulse advances it by exactly one grid step, so every pulse lands a
    // sample and the pill moves once per pulse — which is what makes the
    // harness a fair review of the shipped cadence.
    _simulatedMillis += kSmoothnessSampleInterval.inMilliseconds;
    if (_tracker.observe(
      nowMillis: _simulatedMillis,
      speedKmh: _car.liveSpeedKmh,
      drivePowerKw: _car.livePowerKw,
    )) {
      _smoothnessNotifier.value = _tracker.readingAt(_simulatedMillis);
    }
  }

  /// The clock [_publishSmoothness] hands the tracker. See there.
  int _simulatedMillis = 0;

  /// Fills the tracker's window before the first frame.
  ///
  /// The harness pre-fills the buckets so the line opens full. The pill has to
  /// open full for the same reason: a reviewer judging the card should see what
  /// it looks like mid-drive, not the empty track it shows for the first thirty
  /// seconds of one.
  void _seedSmoothness() {
    final steps =
        kSmoothnessWindow.inMilliseconds ~/
        kSmoothnessSampleInterval.inMilliseconds;
    for (var i = 0; i < steps; i++) {
      _car.pulse(_driving);
      _publishSmoothness();
    }
  }

  /// `EfficiencyCard` takes the reading as a listenable so the pill rebuilds
  /// without the line.
  final ValueNotifier<DrivingSmoothness> _smoothnessNotifier = ValueNotifier(
    DrivingSmoothness.unavailable,
  );

  @override
  Widget build(BuildContext context) {
    // Reduced once and passed down. Both cards read the same series, and it is
    // the same reduction the product runs, so computing it per call site would
    // triple the harness's cost against the card's.
    final series = _series;
    // The app still runs on AutomotiveTheme, so the gallery supplies the new
    // theme locally, exactly as the other harnesses do.
    return Theme(
      data: AppTheme.light(),
      child: Scaffold(
        backgroundColor: AppColors.canvas,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: AppSpacing.screenPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _liveCard(series),
                const SizedBox(height: AppSpacing.gridGutter),
                _statesCard(),
                const SizedBox(height: AppSpacing.gridGutter),
                _readingCard(series),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The card as it would ship, fed by the simulator.
  Widget _liveCard(EfficiencySeries series) {
    return AppCard(
      title: 'Efficiency',
      subtitle: '${_driving.label} · ${_driving.note}',
      trailing: SizedBox(
        width: 180,
        child: SoftActionTile(
          label: _running ? 'Pause' : 'Run',
          icon: _running ? Icons.pause : Icons.play_arrow,
          centered: true,
          onPressed: () {
            setState(() => _running = !_running);
            _restart();
          },
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TrackSegmentedControl<_Driving>(
            items: [
              for (final driving in _Driving.values)
                TabItem(value: driving, label: driving.label),
            ],
            selected: _driving,
            onSelected: (value) => setState(() => _driving = value),
          ),
          const SizedBox(height: AppSpacing.gridGutter),
          SizedBox(
            height: 200,
            child: EfficiencyCard(
              series: series,
              smoothness: _smoothnessNotifier,
              unit: _unit,
              unitSuffix: _unitSuffix(_unit),
              onCycleUnit: () => setState(_cycleUnit),
              ceilingWhPerKm: _ceilingWhPerKm,
              // The line's colour divider only. The pill measures technique
              // and has no efficiency reference, so moving this recolours the
              // history and leaves the knob where it was. With `None` it falls
              // back to the middle of the axis.
              neutral: _reference,
              floorLabel: 'Less range',
              unitLabel: 'Wh/km',
              averageCaption: 'avg. · last 15 min',
              referenceCaption: 'driving smoothness',
              referenceDetail: 'last 30 s',
            ),
          ),
          const SizedBox(height: AppSpacing.gridGutter),
          _windowControl(),
          const SizedBox(height: AppSpacing.gridGutter),
          _unitControl(series),
          const SizedBox(height: AppSpacing.gridGutter),
          Row(
            children: [
              Expanded(child: _ceilingControl()),
              const SizedBox(width: AppSpacing.gridGutter),
              Expanded(
                child: SoftActionTile(
                  label: 'Drop the signal for 30 s',
                  icon: Icons.signal_cellular_off,
                  centered: true,
                  onPressed: () => setState(() => _car.blackout(3)),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.gridGutter),
          Row(
            children: [
              Expanded(child: _referenceControl()),
              const SizedBox(width: AppSpacing.gridGutter),
              Expanded(
                child: SoftActionTile(
                  label: 'Floor it for 3 s',
                  icon: Icons.speed,
                  centered: true,
                  onPressed: () => setState(_car.floorIt),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The window is the whole point of the card's second version.
  ///
  /// Regeneration returns energy that was spent in an earlier bucket, so a
  /// point narrower than the spend-and-recover cycle reports the climb and the
  /// descent as two different verdicts about one stretch of driving. At ten
  /// seconds the cost line tears apart; by three minutes it is a trace you can
  /// follow. Nothing else on this screen shows that as directly as dragging
  /// this control while Town is running.
  Widget _windowControl() {
    return TrackSegmentedControl<Duration>(
      items: const [
        TabItem(value: Duration.zero, label: 'per bucket'),
        TabItem(value: Duration(minutes: 1), label: '1 min'),
        TabItem(value: kEfficiencyWindow, label: '3 min · shipping'),
        TabItem(value: Duration(minutes: 5), label: '5 min'),
      ],
      selected: _window,
      onSelected: (value) => setState(() => _window = value),
    );
  }

  /// Demo labels only. This harness never ships, so it is exempt from ARB.
  static String _unitSuffix(EfficiencyUnit unit) => switch (unit) {
    EfficiencyUnit.kmPerKwh => 'km/kWh',
    EfficiencyUnit.kwhPer50km => 'kWh/50km',
    EfficiencyUnit.kwhPer100km => 'kWh/100km',
  };

  void _cycleUnit() {
    _unit =
        EfficiencyUnit.values[(_unit.index + 1) % EfficiencyUnit.values.length];
  }

  /// The reader's unit, and the same reading printed in all three.
  ///
  /// In the car the choice is made by tapping the numeral on the card itself,
  /// or in Settings. The segmented control here is the harness's shortcut to
  /// any one of the three without three taps, and the row under it shows what
  /// the switch does to one value — the same ratio, said three ways — which a
  /// card showing one unit at a time cannot.
  Widget _unitControl(EfficiencySeries series) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TrackSegmentedControl<EfficiencyUnit>(
          items: [
            for (final unit in EfficiencyUnit.values)
              TabItem(value: unit, label: _unitSuffix(unit)),
          ],
          selected: _unit,
          onSelected: (value) => setState(() => _unit = value),
        ),
        const SizedBox(height: AppSpacing.x3),
        Row(
          children: [
            for (final unit in EfficiencyUnit.values)
              Expanded(
                child: _unitSample(
                  label: _unitSuffix(unit),
                  value: formatEfficiencyForUnit(series.averageKmPerKwh, unit),
                  selected: unit == _unit,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _unitSample({
    required String label,
    required String value,
    required bool selected,
  }) {
    final colors = AppThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            style: AppText.metricMd.copyWith(
              color: selected ? colors.ink : colors.inkSubtle,
            ),
          ),
          Text(
            label,
            maxLines: 1,
            style: AppText.caption.copyWith(
              color: selected ? colors.inkMuted : colors.inkSubtle,
            ),
          ),
        ],
      ),
    );
  }

  /// The ceiling is a judgement, not a measurement.
  ///
  /// It decides how much of an ordinary drive is legible and how much clips.
  /// Too low and an ordinary stretch pins against the bottom; too high and the
  /// whole line sits in the top third. This control is here to settle it by
  /// looking, which is the only way it can be settled. Measured over the
  /// recorded drives, a three-minute window keeps cost under 250 Wh/km on the
  /// open road and pushes past 600 in stop-start crawling.
  Widget _ceilingControl() {
    return TrackSegmentedControl<double>(
      items: const [
        TabItem(value: 200.0, label: '200 Wh/km'),
        TabItem(value: 300.0, label: '300 Wh/km'),
        TabItem(value: 400.0, label: '400 Wh/km'),
        TabItem(value: 600.0, label: '600 Wh/km'),
      ],
      selected: _ceilingWhPerKm,
      onSelected: (value) => setState(() => _ceilingWhPerKm = value),
    );
  }

  /// Where neutral sits.
  ///
  /// In the car this is `RangeEstimate.efficiencyKmPerKwh` and the driver never
  /// picks it. Here it is a control so the neutral point can be moved while the
  /// driving stays the same, which is the only way to see that the pill is a
  /// comparison and not a second efficiency readout. `None` is the degraded
  /// estimate: no reference, no knob.
  Widget _referenceControl() {
    return TrackSegmentedControl<double?>(
      items: const [
        TabItem(value: 4.0, label: 'Ref 4'),
        TabItem(value: 6.0, label: 'Ref 6'),
        TabItem(value: 8.0, label: 'Ref 8'),
        TabItem(value: null, label: 'None'),
      ],
      selected: _reference,
      onSelected: (value) => setState(() => _reference = value),
    );
  }

  /// Each state on its own, held still.
  ///
  /// The live card cannot be paused on the interesting frame, and these are the
  /// five shapes the painter has to get right.
  Widget _statesCard() {
    return AppCard(
      title: 'One state at a time',
      subtitle: 'held still, so the shape can be checked',
      child: Wrap(
        spacing: AppSpacing.gridGutter,
        runSpacing: AppSpacing.gridGutter,
        children: [
          for (final sample in _fixtures)
            SizedBox(
              width: 300,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _caption(sample.label),
                  const SizedBox(height: AppSpacing.x2),
                  EfficiencyChart(
                    series: sample.series,
                    ceilingWhPerKm: _ceilingWhPerKm,
                    height: 120,
                    floorLabel: 'Less range',
                    unitLabel: 'Wh/km',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// What the maths says, next to what the chart drew.
  ///
  /// A chart can look right while the numbers behind it are wrong. This table
  /// is how a shape on screen gets traced back to the buckets that made it.
  Widget _readingCard(EfficiencySeries series) {
    final counts = <EfficiencyState, int>{};
    for (final point in series.points) {
      counts[point.state] = (counts[point.state] ?? 0) + 1;
    }
    final head = series.head;
    // The claim the window has to keep: it changes what a point answers over,
    // never what the fifteen minutes cost. Printed side by side so a drift
    // shows up here instead of in the field.
    final perBucket = readEfficiency(_car.buckets, window: Duration.zero);
    return AppCard(
      title: 'What the maths says',
      subtitle:
          '${series.points.length} buckets · ${_bucket.inSeconds} s each · '
          'each point reads back '
          '${_window == Duration.zero ? 'its own bucket' : '${_window.inMinutes} min'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('window distance', '${series.distanceKm.toStringAsFixed(2)} km'),
          _row('window net energy', '${series.netWh.toStringAsFixed(0)} Wh'),
          _row(
            'window average',
            '${formatEfficiency(series.averageKmPerKwh)} km/kWh',
          ),
          _row(
            'same, read per bucket',
            '${formatEfficiency(perBucket.averageKmPerKwh)} km/kWh '
                '(must be identical)',
          ),
          _row(
            'mean of the ratios',
            '${formatEfficiency(_meanOfRatios(series))} km/kWh '
                '(what it must NOT be)',
          ),
          _row(
            'head',
            '${head?.state.name ?? '--'} · '
                '${formatEfficiency(head?.kmPerKwh)}',
          ),
          const SizedBox(height: AppSpacing.x3),
          // The three terms the two lines and their band are drawn from. In
          // Wh/km they subtract, which is the whole reason both fit on one
          // axis; the third row is that subtraction, checked.
          _row('head demand', _whPerKm(head?.drawnWhPerKm)),
          _row('head recovered', _whPerKm(_recoveredWhPerKm(head))),
          _row('head cost', _whPerKm(head?.netWhPerKm)),
          const SizedBox(height: AppSpacing.x3),
          for (final state in EfficiencyState.values)
            _row(state.name, '${counts[state] ?? 0}'),
          const SizedBox(height: AppSpacing.x3),
          // The pill's own terms, so a knob position can be traced back to the
          // two live signals behind it rather than to the buckets above.
          //
          // These are the only rows on the screen that run at bus rate, so they
          // get their own builder — the same arrangement the card uses for the
          // pill, and for the same reason.
          ValueListenableBuilder<DrivingSmoothness>(
            valueListenable: _smoothnessNotifier,
            builder: (context, smoothness, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row(
                  'live speed',
                  '${_car.liveSpeedKmh.toStringAsFixed(1)} km/h',
                ),
                _row('live power', '${_car.livePowerKw.toStringAsFixed(1)} kW'),
                _row('smoothness state', smoothness.state.name),
                _row(
                  'ramp',
                  smoothness.rampKwPerKm == null
                      ? '--'
                      : '${smoothness.rampKwPerKm!.toStringAsFixed(0)} kW/km '
                            '(${kSmoothnessReferenceRampKwPerKm.toStringAsFixed(0)} '
                            'is neutral)',
                ),
                _row(
                  'knob · tick',
                  '${smoothness.standing?.toStringAsFixed(2) ?? '--'} · '
                      '${smoothness.instant?.toStringAsFixed(2) ?? '--'}',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The band's own thickness, in the axis's unit.
  double? _recoveredWhPerKm(EfficiencyPoint? point) {
    if (point == null) return null;
    final demand = point.drawnWhPerKm;
    final cost = point.netWhPerKm;
    return (demand == null || cost == null) ? null : demand - cost;
  }

  String _whPerKm(double? value) =>
      value == null ? '--' : '${value.toStringAsFixed(0)} Wh/km';

  double? _meanOfRatios(EfficiencySeries series) {
    final values = series.points
        .map((point) => point.kmPerKwh)
        .whereType<double>()
        .toList(growable: false);
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a + b) / values.length;
  }

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.x1),
    child: Row(
      children: [
        SizedBox(width: 200, child: _caption(label)),
        Expanded(
          child: Text(
            value,
            style: AppText.bodyStrong.copyWith(color: AppColors.ink),
          ),
        ),
      ],
    ),
  );

  Widget _caption(String text) =>
      Text(text, style: AppText.caption.copyWith(color: AppColors.inkMuted));

  /// Built once. It was a getter, and the pulse rebuilt the screen 25 times a
  /// second, so five simulated cars were constructed and reduced on every frame
  /// to draw five panels that never move.
  late final List<_Fixture> _fixtures = [
    _Fixture('Steady cruise', _Driving.highway),
    _Fixture('Town, with regeneration', _Driving.town),
    _Fixture('Stopped, climate running', _Driving.crawl),
    _Fixture('Long descent', _Driving.descent),
    _Fixture('Reporting nothing', _Driving.parked),
  ];
}

class _Fixture {
  /// Read at the bucket, not through the window.
  ///
  /// These panels exist to hold one state still so its shape can be checked.
  /// The trailing window is what makes a ratio exist, so it reduces the states
  /// that name a ratio's absence to almost nothing — which is the fix working,
  /// and exactly the wrong thing for a panel whose job is to show them.
  _Fixture(this.label, _Driving driving) {
    final car = _SimulatedCar(seed: label.length * 31);
    car.fill(45, driving);
    series = readEfficiency(car.buckets, window: Duration.zero);
  }

  final String label;
  late final EfficiencySeries series;
}

/// Produces ten-second energy buckets the way the car would.
///
/// It emits energy and distance, never an efficiency: the harness has to go
/// through the same reduction the product does, or it would be checking the
/// painter against numbers no car could produce.
class _SimulatedCar {
  _SimulatedCar({int seed = 11}) : _random = math.Random(seed);

  final math.Random _random;
  final List<EnergyBucket> _buckets = [];

  /// Auxiliary draw over ten seconds. About 1.3 kW: climate, lights, computers.
  static const _auxiliaryWh = 3.6;

  static const _width = Duration(seconds: 10);
  static const _capacity = 90;

  DateTime _cursor = DateTime.utc(2026, 8, 6, 21);

  double _speedKmh = 0;
  double _powerKw = 0;
  int _floorTicks = 0;

  List<EnergyBucket> get buckets => List.unmodifiable(_buckets);

  /// The bus values behind the pill, on their own clock.
  ///
  /// The real car reports these continuously and they are what makes the knob
  /// answer the pedal. They are simulated separately from the buckets for the
  /// same reason the product reads them separately: one is now, the other is
  /// the last closed interval.
  double get liveSpeedKmh => _speedKmh;
  double get livePowerKw => _powerKw;

  /// Advances the live signals one frame toward what the driving asks for.
  ///
  /// Speed is heavy and power is not. That asymmetry is the whole reason the
  /// knob drops under acceleration: the denominator can multiply in a second
  /// while the numerator has barely started to move.
  void pulse(_Driving driving) {
    if (_floorTicks > 0) {
      _floorTicks--;
      _speedKmh += (110 - _speedKmh) * 0.01;
      _powerKw += (140 - _powerKw) * 0.25;
      return;
    }
    final (targetSpeed, targetPower) = _target(driving);
    _speedKmh += (targetSpeed - _speedKmh) * 0.02;
    _powerKw += (targetPower - _powerKw) * 0.12;
  }

  /// Full throttle for about three seconds of harness time.
  void floorIt() => _floorTicks = 75;

  (double, double) _target(_Driving driving) => switch (driving) {
    _Driving.highway => (95, 20),
    _Driving.town => (38, 16),
    _Driving.crawl => (6, 3),
    _Driving.descent => (70, -6),
    _Driving.parked => (0, 0),
  };

  void fill(int count, _Driving driving) {
    for (var index = 0; index < count; index++) {
      advance(driving);
    }
  }

  /// Adds one interval and drops the oldest once the window is full.
  void advance(_Driving driving) {
    _buckets.add(_next(driving));
    while (_buckets.length > _capacity) {
      _buckets.removeAt(0);
    }
  }

  /// Adds [count] intervals the car reported nothing for.
  void blackout(int count) {
    for (var index = 0; index < count; index++) {
      _buckets.add(
        EnergyBucket(
          start: _advanceCursor(),
          width: _width,
          tractionWh: 0,
          regeneratedWh: 0,
          auxiliaryWh: 0,
          integratedSeconds: 0,
        ),
      );
      while (_buckets.length > _capacity) {
        _buckets.removeAt(0);
      }
    }
  }

  EnergyBucket _next(_Driving driving) {
    if (driving == _Driving.parked) {
      return EnergyBucket(
        start: _advanceCursor(),
        width: _width,
        tractionWh: 0,
        regeneratedWh: 0,
        auxiliaryWh: 0,
        integratedSeconds: 0,
      );
    }

    final (speedKmh, driveKw) = switch (driving) {
      _Driving.highway => (95.0 + _jitter(14), 20.0 + _jitter(7)),
      _Driving.town => _townSample(),
      _Driving.crawl =>
        _random.nextDouble() < 0.6
            ? (0.0, 0.0)
            : (7.0 + _jitter(4), 4.0 + _jitter(3)),
      _Driving.descent => (70.0 + _jitter(12), -6.0 + _jitter(9)),
      _Driving.parked => (0.0, 0.0),
    };

    final seconds = _width.inSeconds.toDouble();
    final driveWh = driveKw * seconds / 3.6;
    return EnergyBucket(
      start: _advanceCursor(),
      width: _width,
      tractionWh: math.max(0, driveWh),
      regeneratedWh: math.max(0, -driveWh),
      auxiliaryWh: _auxiliaryWh,
      integratedSeconds: seconds,
      speedDistanceKm: math.max(0, speedKmh) * seconds / 3600,
      speedIntegratedSeconds: seconds,
    );
  }

  /// Town driving: accelerate, cruise, brake into regeneration, stop.
  (double, double) _townSample() {
    final phase = _random.nextDouble();
    return switch (phase) {
      < 0.18 => (0.0, 0.0), // waiting at a light
      < 0.36 => (22.0 + _jitter(10), -14.0 + _jitter(6)), // braking
      < 0.58 => (18.0 + _jitter(12), 34.0 + _jitter(14)), // pulling
      _ => (42.0 + _jitter(16), 14.0 + _jitter(9)), // rolling
    };
  }

  double _jitter(double span) => (_random.nextDouble() - 0.5) * span;

  DateTime _advanceCursor() {
    final start = _cursor;
    _cursor = _cursor.add(_width);
    return start;
  }
}
