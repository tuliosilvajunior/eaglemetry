import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../capy_ui.dart';

/// Developer-only harness for [EnergyBarChart] value motion.
///
/// The main gallery shows the chart in fixed states. This one shows it while
/// its numbers change, which is the only way to judge the two movements the
/// component makes: a bucket that already exists and reports a larger reading
/// travels to it, and a bucket that appears for the first time rises from the
/// axis.
///
/// What to look for:
///
///  * The live bucket must grow. It must never arrive at its new height on the
///    frame the reading lands.
///  * A reading that arrives while the bar still travels must carry on from
///    the height on screen. A bar that drops back and starts again is the
///    defect this harness exists to catch.
///  * A growth must not overshoot. Only an entrance carries a bounce.
///  * The bars already on screen must hold still while a new one enters.
///
/// The screen also puts the two [ChartGrowth] options beside each other on one
/// data source, because the choice between them is a judgement that only
/// looking can settle.
///
/// The copy here is demo text, not product copy — this screen never ships to a
/// user, so it is exempt from the ARB rule that governs real screens.
class ChartMotionGalleryScreen extends StatefulWidget {
  const ChartMotionGalleryScreen({super.key});

  @override
  State<ChartMotionGalleryScreen> createState() =>
      _ChartMotionGalleryScreenState();
}

/// How often a reading arrives in the live card.
enum _Rate {
  slow(Duration(milliseconds: 1000), '1000 ms'),
  medium(Duration(milliseconds: 500), '500 ms'),
  fast(Duration(milliseconds: 250), '250 ms');

  const _Rate(this.period, this.label);

  final Duration period;
  final String label;
}

class _ChartMotionGalleryScreenState extends State<ChartMotionGalleryScreen> {
  /// Readings that arrive before one bucket closes and the next opens.
  ///
  /// Five is enough to watch a bar travel several times over, and still short
  /// enough that an entrance comes round often.
  static const _readingsPerBucket = 5;

  /// Slots in the plotted window. The series slides once it fills, which is
  /// what proves a bar keeps its own start value when the grid moves under it.
  static const _slots = 24;

  static const _ceiling = 6.0;

  final _live = _Series(seed: 7, slots: _slots);
  final _manual = _Series(seed: 21, slots: _slots);

  _Rate _rate = _Rate.slow;
  bool _running = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    if (!_running) return;
    _timer = Timer.periodic(_rate.period, (_) {
      setState(() => _live.advance(_readingsPerBucket));
    });
  }

  @override
  Widget build(BuildContext context) {
    // The app still runs on AutomotiveTheme, so the gallery supplies the new
    // theme locally, exactly as `UiGalleryScreen` does.
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
                _liveCard(),
                const SizedBox(height: AppSpacing.gridGutter),
                _manualCard(),
                const SizedBox(height: AppSpacing.gridGutter),
                _notesCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A reading every [_Rate.period], as telemetry delivers one.
  ///
  /// The rate control is the point of this card. At 1000 ms a growth of 180 ms
  /// settles long before the next reading. At 250 ms it barely does, and the
  /// bar starts to read as one continuous slide instead of a series of steps.
  Widget _liveCard() {
    return AppCard(
      title: 'Live series',
      subtitle:
          'A reading every ${_rate.label} · a bucket closes every '
          '$_readingsPerBucket readings',
      trailing: SizedBox(
        width: 180,
        child: SoftActionTile(
          label: _running ? 'Pause' : 'Run',
          icon: _running ? Icons.pause : Icons.play_arrow,
          centered: true,
          onPressed: () {
            setState(() => _running = !_running);
            _restartTimer();
          },
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TrackSegmentedControl<_Rate>(
            items: [
              for (final rate in _Rate.values)
                TabItem(value: rate, label: rate.label),
            ],
            selected: _rate,
            onSelected: (value) {
              setState(() => _rate = value);
              _restartTimer();
            },
          ),
          const SizedBox(height: AppSpacing.gridGutter),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _labelled(
                    'ChartGrowth.settle — 180 ms, then it waits',
                    _chart(_live, growth: ChartGrowth.settle),
                  ),
                ),
                const SizedBox(width: AppSpacing.gridGutter),
                Expanded(
                  child: _labelled(
                    'ChartGrowth.chase(${_rate.label}) — it never pauses',
                    _chart(_live, growth: ChartGrowth.chase(_rate.period)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
          _caption(
            'Watch the open bucket on each side. The left one steps: it climbs '
            'for 180 ms and then holds. The right one never holds, because '
            'every reading redirects a travel that is still running. Change '
            'the rate to see how far each idea carries.',
          ),
        ],
      ),
    );
  }

  /// The same series, one reading per press, with the motion beside its own
  /// absence.
  ///
  /// A single step is too short to judge while a timer keeps firing. Holding
  /// the series still between presses is what makes one travel watchable, and
  /// the right-hand chart says what the bar would do with no motion at all.
  Widget _manualCard() {
    return AppCard(
      title: 'One reading at a time',
      subtitle:
          'One data source, three treatments · the rate control above '
          'sets the chase period',
      trailing: SizedBox(
        width: 180,
        child: SoftActionTile(
          label: 'Reset',
          icon: Icons.restart_alt,
          centered: true,
          onPressed: () => setState(_manual.reset),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SoftActionTile(
                  label: 'Grow the open bucket',
                  icon: Icons.trending_up,
                  centered: true,
                  onPressed: () => setState(() => _manual.grow()),
                ),
              ),
              const SizedBox(width: AppSpacing.gridGutter),
              Expanded(
                child: SoftActionTile(
                  label: 'Close it and open the next',
                  icon: Icons.add,
                  centered: true,
                  onPressed: () => setState(() => _manual.close()),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.gridGutter),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _labelled(
                    'animate: false — no motion at all',
                    _chart(_manual, animate: false),
                  ),
                ),
                const SizedBox(width: AppSpacing.gridGutter),
                Expanded(
                  child: _labelled(
                    'ChartGrowth.settle',
                    _chart(_manual, growth: ChartGrowth.settle),
                  ),
                ),
                const SizedBox(width: AppSpacing.gridGutter),
                Expanded(
                  child: _labelled(
                    'ChartGrowth.chase(${_rate.label})',
                    _chart(_manual, growth: ChartGrowth.chase(_rate.period)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.x2),
          _caption(
            'Press "Grow" twice in quick succession. Both animated bars must '
            'continue upward from where they stand. The chase bar shows the '
            'redirection best, because its travel is still running when the '
            'second press lands.',
          ),
        ],
      ),
    );
  }

  Widget _notesCard() {
    return AppCard(
      title: 'What this harness checks',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final note in const [
            'ChartGrowth.settle: a bucket travels to its reading over 180 ms '
                'and then holds until the next one.',
            'ChartGrowth.chase(period): one travel lasts a whole period, so '
                'the next reading redirects it and the bar never stops. It '
                'reads about one reading low for as long as the series moves.',
            'A reading that arrives mid-travel continues from the height on '
                'screen. It does not restart from the previous reading.',
            'A growth carries no bounce and no stagger. Only an entrance does.',
            'A new bucket rises from the axis while every bar already on '
                'screen holds still.',
            'Once the window fills, the series slides and each bar keeps its '
                'own height, because a bar is matched by EnergyBar.id.',
            'The reference curve travels with the bars it belongs to.',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.x2),
              child: _caption('· $note'),
            ),
        ],
      ),
    );
  }

  Widget _labelled(String label, Widget chart) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _caption(label),
      const SizedBox(height: AppSpacing.x2),
      SizedBox(height: 300, child: chart),
    ],
  );

  Widget _chart(
    _Series series, {
    bool animate = true,
    ChartGrowth growth = ChartGrowth.settle,
  }) {
    final bars = series.bars;
    return EnergyBarChart(
      animate: animate,
      growth: growth,
      slotCount: _slots,
      bars: bars,
      // The curve is the same reading in another form, so it must move with
      // the bar it sits on rather than snap ahead of it.
      overlay: series.overlay,
      overlayAnchor: ChartOverlayAnchor.start,
      ticks: const [
        ChartTick(value: _ceiling, label: '6.0'),
        ChartTick(value: _ceiling * 2 / 3, label: '4.0'),
        ChartTick(value: _ceiling / 3, label: '2.0'),
        ChartTick(value: 0, label: '0.0'),
      ],
    );
  }

  Widget _caption(String text) =>
      Text(text, style: AppText.caption.copyWith(color: AppColors.inkSubtle));
}

/// Demo telemetry: a run of closed buckets and one open bucket that grows.
///
/// Values are drawn from a seeded generator, so a reload gives the same series
/// and two charts fed by the same instance always agree.
class _Series {
  _Series({required this.seed, required this.slots}) {
    reset();
  }

  final int seed;

  /// Width of the plotted window, so a reset can never seed more buckets than
  /// the chart has slots to hold.
  final int slots;

  /// Buckets that will not change again.
  final _closed = <double>[];

  /// Absolute index of the oldest bucket held, so an identity survives the
  /// window sliding.
  var _firstIndex = 0;

  var _open = 0.0;
  var _readings = 0;
  late math.Random _random;

  void reset() {
    _random = math.Random(seed);
    _closed.clear();
    _firstIndex = 0;
    _open = _step();
    _readings = 1;
    for (var i = 0; i < 6; i++) {
      close();
    }
  }

  /// One reading into the open bucket.
  void grow() {
    _open = math.min(_open + _step(), 5.6);
    _readings++;
  }

  /// Closes the open bucket and opens the next one.
  void close() {
    _closed.add(_open);
    if (_closed.length >= slots) {
      _closed.removeAt(0);
      _firstIndex++;
    }
    _open = _step();
    _readings = 1;
  }

  /// One tick of the live card: a reading, and a new bucket every
  /// [readingsPerBucket] of them.
  void advance(int readingsPerBucket) {
    if (_readings >= readingsPerBucket) {
      close();
    } else {
      grow();
    }
  }

  double _step() => 0.35 + _random.nextDouble() * 0.85;

  List<EnergyBar> get bars => [
    for (var i = 0; i < _closed.length; i++)
      EnergyBar(id: _firstIndex + i, value: _closed[i]),
    EnergyBar(id: _firstIndex + _closed.length, value: _open),
  ];

  /// A reference curve over the same buckets, so the overlay path is exercised
  /// by the same readings that drive the bars.
  List<double> get overlay => [for (final bar in bars) bar.value * 1.08];
}
