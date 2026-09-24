import 'dart:math' as math;

/// Explicação dominante do Eco Coach naquele instante.
///
/// A nota é deliberadamente heurística: ela descreve suavidade e demanda, não
/// tenta adivinhar se o motorista *precisava* acelerar por causa do trânsito.
enum EcoCoachReason {
  observing,
  stopped,
  efficientDemand,
  highDemand,
  abruptAcceleration,
  abruptJerk,
  coasting,
  regenerating,
  accelerateThenBrake,
}

enum EcoCoachReasonSeverity { positive, warning, critical }

extension EcoCoachReasonSeverityValue on EcoCoachReason {
  EcoCoachReasonSeverity get severity => switch (this) {
    EcoCoachReason.observing ||
    EcoCoachReason.stopped ||
    EcoCoachReason.efficientDemand ||
    EcoCoachReason.coasting ||
    EcoCoachReason.regenerating => EcoCoachReasonSeverity.positive,
    EcoCoachReason.highDemand => EcoCoachReasonSeverity.warning,
    EcoCoachReason.abruptAcceleration ||
    EcoCoachReason.abruptJerk ||
    EcoCoachReason.accelerateThenBrake => EcoCoachReasonSeverity.critical,
  };
}

const Duration kEcoCoachReasonVisibility = Duration(seconds: 5);

class EcoCoachInput {
  const EcoCoachInput({
    required this.timestamp,
    required this.speedKmh,
    required this.drivePowerKw,
    required this.pedalFraction,
    required this.brakePressed,
    this.motionTimestamp,
    this.motionSampleChanged = true,
  });

  final Duration timestamp;
  final double? speedKmh;
  final double? drivePowerKw;
  final double? pedalFraction;
  final bool? brakePressed;
  final Duration? motionTimestamp;
  final bool motionSampleChanged;
}

class EcoCoachSnapshot {
  const EcoCoachSnapshot({
    required this.score,
    required this.reason,
    required this.observedAt,
    required this.reasonWindows,
    required this.accelerationMps2,
    required this.jerkMps3,
    required this.demandFraction,
    required this.coasting,
    required this.accelerateBrakeCycles,
  });

  const EcoCoachSnapshot.empty()
    : score = null,
      reason = EcoCoachReason.observing,
      observedAt = Duration.zero,
      reasonWindows = const <EcoCoachReasonWindow>[],
      accelerationMps2 = null,
      jerkMps3 = null,
      demandFraction = null,
      coasting = false,
      accelerateBrakeCycles = 0;

  final double? score;
  final EcoCoachReason reason;
  final Duration observedAt;
  final List<EcoCoachReasonWindow> reasonWindows;
  final double? accelerationMps2;
  final double? jerkMps3;
  final double? demandFraction;
  final bool coasting;
  final int accelerateBrakeCycles;

  /// Motivos que ainda estão dentro da janela de visibilidade.
  List<EcoCoachReason> get activeReasons => activeReasonsAt(observedAt);

  /// Permite à UI expirar a lista mesmo entre duas amostras do barramento.
  List<EcoCoachReason> activeReasonsAt(Duration timestamp) => reasonWindows
      .where((window) => timestamp < window.visibleUntil)
      .map((window) => window.reason)
      .toList(growable: false);
}

class EcoCoachReasonWindow {
  const EcoCoachReasonWindow({
    required this.reason,
    required this.visibleUntil,
  });

  final EcoCoachReason reason;
  final Duration visibleUntil;

  double opacityAt(Duration timestamp) {
    final remaining = (visibleUntil - timestamp).inMicroseconds;
    if (remaining <= 0) return 0;
    return (remaining / kEcoCoachReasonVisibility.inMicroseconds).clamp(
      0.0,
      1.0,
    );
  }
}

/// Eco Coach v1, calculado apenas com sinais já confirmados na tela ao vivo.
///
/// Os limiares são explícitos para a captura controlada poder refiná-los. A nota
/// combina demanda de tração, aceleração, jerk e o desperdício observável de uma
/// aceleração seguida logo por freio. Ela não é eficiência energética em km/kWh.
class EcoCoachEngine {
  EcoCoachEngine({this.calibration = const EcoCoachCalibration()});

  final EcoCoachCalibration calibration;

  Duration? _previousTimestamp;
  double? _previousSpeedMps;
  double? _filteredAcceleration;
  int _accelerationSamples = 0;
  double? _score;
  int? _lastDemandMs;
  int? _cycleReasonUntilMs;
  bool _previousBrake = false;
  int _cycles = 0;
  final Map<EcoCoachReason, int> _reasonVisibleUntilMs = {};

  EcoCoachSnapshot observe(EcoCoachInput input) {
    final nowMs = input.timestamp.inMilliseconds;
    final motionTimestamp = input.motionTimestamp ?? input.timestamp;
    final speedKmh = input.speedKmh;
    final speedMps = speedKmh == null ? null : speedKmh / 3.6;
    double? acceleration = input.motionSampleChanged
        ? null
        : _filteredAcceleration;
    double? jerk;

    if (input.motionSampleChanged &&
        speedMps != null &&
        _previousSpeedMps != null &&
        _previousTimestamp != null) {
      final seconds =
          (motionTimestamp - _previousTimestamp!).inMicroseconds / 1000000;
      if (seconds >= calibration.minimumSampleSeconds &&
          seconds <= calibration.maximumSampleSeconds) {
        final rawAcceleration = (speedMps - _previousSpeedMps!) / seconds;
        final oldAcceleration = _filteredAcceleration;
        acceleration = oldAcceleration == null
            ? rawAcceleration
            : _mix(
                oldAcceleration,
                rawAcceleration,
                calibration.accelerationFilter,
              );
        if (oldAcceleration != null && _accelerationSamples >= 1) {
          jerk = (acceleration - oldAcceleration) / seconds;
        }
        _filteredAcceleration = acceleration;
        _accelerationSamples++;
      } else if (seconds > calibration.maximumSampleSeconds) {
        _filteredAcceleration = null;
        _accelerationSamples = 0;
      }
    }
    if (input.motionSampleChanged && speedMps != null) {
      _previousSpeedMps = speedMps;
      _previousTimestamp = motionTimestamp;
    }

    final moving = speedKmh != null && speedKmh >= calibration.movingKmh;
    final positivePower = math.max(input.drivePowerKw ?? 0, 0).toDouble();
    final powerDemand = positivePower / calibration.highDemandPowerKw;
    final pedalDemand = input.pedalFraction == null
        ? 0.0
        : input.pedalFraction! / calibration.highDemandPedalFraction;
    final demand = math.max(powerDemand, pedalDemand).clamp(0.0, 1.0);
    final demanding =
        moving &&
        (positivePower >= calibration.cycleArmPowerKw ||
            (acceleration ?? 0) >= calibration.cycleArmAccelerationMps2);
    if (demanding) _lastDemandMs = nowMs;

    final brake = input.brakePressed == true;
    if (brake && !_previousBrake && moving) {
      final sinceDemand = _lastDemandMs == null ? null : nowMs - _lastDemandMs!;
      if (sinceDemand != null &&
          sinceDemand >= 0 &&
          sinceDemand <= calibration.accelerateBrakeWindow.inMilliseconds) {
        _cycles++;
        _cycleReasonUntilMs = nowMs + calibration.reasonHold.inMilliseconds;
        _lastDemandMs = null;
      }
    }
    _previousBrake = brake;

    final coasting =
        moving &&
        !brake &&
        (input.pedalFraction ?? 0) <= calibration.coastPedalFraction;
    final regenerating =
        moving && (input.drivePowerKw ?? 0) <= -calibration.regenPowerKw;
    final accelerationPenalty = _ramp(
      acceleration?.abs(),
      calibration.comfortableAccelerationMps2,
      calibration.abruptAccelerationMps2,
    );
    final jerkPenalty = _ramp(
      jerk?.abs(),
      calibration.comfortableJerkMps3,
      calibration.abruptJerkMps3,
    );
    final cycleActive =
        _cycleReasonUntilMs != null && nowMs <= _cycleReasonUntilMs!;

    final reason = !moving
        ? (speedKmh == null ? EcoCoachReason.observing : EcoCoachReason.stopped)
        : acceleration == null
        ? EcoCoachReason.observing
        : cycleActive
        ? EcoCoachReason.accelerateThenBrake
        : jerkPenalty >= 0.25
        ? EcoCoachReason.abruptJerk
        : accelerationPenalty >= 0.25
        ? EcoCoachReason.abruptAcceleration
        : demand >= 0.65
        ? EcoCoachReason.highDemand
        : regenerating
        ? EcoCoachReason.regenerating
        : coasting
        ? EcoCoachReason.coasting
        : EcoCoachReason.efficientDemand;

    final detectedReasons = <EcoCoachReason>[
      if (!moving && speedKmh != null) EcoCoachReason.stopped,
      if (moving && acceleration != null) ...[
        if (cycleActive) EcoCoachReason.accelerateThenBrake,
        if (jerkPenalty >= 0.25) EcoCoachReason.abruptJerk,
        if (accelerationPenalty >= 0.25) EcoCoachReason.abruptAcceleration,
        if (demand >= 0.65) EcoCoachReason.highDemand,
        if (regenerating) EcoCoachReason.regenerating,
        if (coasting) EcoCoachReason.coasting,
        if (!cycleActive &&
            jerkPenalty < 0.25 &&
            accelerationPenalty < 0.25 &&
            demand < 0.65 &&
            !regenerating &&
            !coasting)
          EcoCoachReason.efficientDemand,
      ],
    ];
    for (final detectedReason in detectedReasons) {
      _reasonVisibleUntilMs[detectedReason] =
          nowMs + calibration.reasonVisibility.inMilliseconds;
    }
    _reasonVisibleUntilMs.removeWhere((_, untilMs) => nowMs >= untilMs);
    final reasonWindows =
        _reasonVisibleUntilMs.entries
            .map(
              (entry) => EcoCoachReasonWindow(
                reason: entry.key,
                visibleUntil: Duration(milliseconds: entry.value),
              ),
            )
            .toList()
          ..sort(
            (left, right) => right.visibleUntil.compareTo(left.visibleUntil),
          );

    if (moving && acceleration != null) {
      final penalty =
          0.45 * demand +
          0.25 * accelerationPenalty +
          0.15 * jerkPenalty +
          (cycleActive ? 0.15 : 0);
      final target = (100 * (1 - penalty)).clamp(0.0, 100.0);
      _score = _score == null
          ? target
          : _mix(_score!, target, calibration.scoreFilter);
    } else if (!moving) {
      _score = null;
    }

    return EcoCoachSnapshot(
      score: _score,
      reason: reason,
      observedAt: input.timestamp,
      reasonWindows: reasonWindows,
      accelerationMps2: acceleration,
      jerkMps3: jerk,
      demandFraction: moving ? demand : null,
      coasting: coasting,
      accelerateBrakeCycles: _cycles,
    );
  }

  void reset() {
    _previousTimestamp = null;
    _previousSpeedMps = null;
    _filteredAcceleration = null;
    _accelerationSamples = 0;
    _score = null;
    _lastDemandMs = null;
    _cycleReasonUntilMs = null;
    _previousBrake = false;
    _cycles = 0;
    _reasonVisibleUntilMs.clear();
  }

  static double _mix(double oldValue, double newValue, double fraction) =>
      oldValue + (newValue - oldValue) * fraction;

  static double _ramp(double? value, double start, double end) {
    if (value == null || value <= start) return 0;
    return ((value - start) / (end - start)).clamp(0.0, 1.0);
  }
}

class EcoCoachCalibration {
  const EcoCoachCalibration({
    this.movingKmh = 3,
    this.minimumSampleSeconds = 0.05,
    this.maximumSampleSeconds = 2,
    this.accelerationFilter = 0.45,
    this.scoreFilter = 0.15,
    this.highDemandPowerKw = 55,
    this.highDemandPedalFraction = 0.7,
    this.comfortableAccelerationMps2 = 0.8,
    this.abruptAccelerationMps2 = 2.2,
    this.comfortableJerkMps3 = 1.0,
    this.abruptJerkMps3 = 3.5,
    this.coastPedalFraction = 0.02,
    this.regenPowerKw = 2,
    this.cycleArmPowerKw = 15,
    this.cycleArmAccelerationMps2 = 0.7,
    this.accelerateBrakeWindow = const Duration(seconds: 8),
    this.reasonHold = const Duration(seconds: 3),
    this.reasonVisibility = kEcoCoachReasonVisibility,
  });

  final double movingKmh;
  final double minimumSampleSeconds;
  final double maximumSampleSeconds;
  final double accelerationFilter;
  final double scoreFilter;
  final double highDemandPowerKw;
  final double highDemandPedalFraction;
  final double comfortableAccelerationMps2;
  final double abruptAccelerationMps2;
  final double comfortableJerkMps3;
  final double abruptJerkMps3;
  final double coastPedalFraction;
  final double regenPowerKw;
  final double cycleArmPowerKw;
  final double cycleArmAccelerationMps2;
  final Duration accelerateBrakeWindow;
  final Duration reasonHold;
  final Duration reasonVisibility;
}
