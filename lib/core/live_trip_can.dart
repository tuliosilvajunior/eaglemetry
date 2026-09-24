import 'dart:math' as math;

import 'package:telemetry_core/telemetry_core.dart';

import 'can_activity.dart';
import 'can_bridge_models.dart';
import 'eco_coach.dart';
import 'live_charge_can.dart'
    show kBattCurrentAssumedZero, kBattCurrentScaleAPerBit;

/// Nomes CAN que a tela live de trip observa.
///
/// A lista é curta de propósito: a leitura em lote custa uma travessia FFI para o
/// conjunto todo, mas cada sinal aqui vira algo desenhado na tela. O que serve para
/// garimpar o barramento é a tela Trace, que observa os 815.
///
/// Os `*Invalid` não são enfeite: são o bit que o próprio ECU usa para dizer "não
/// confie neste valor". Sem eles, um sensor em falha entrega um número plausível e a
/// tela o exibe como medição.
abstract final class LiveTripCanNames {
  /// SOC do pack, calibrado (0,1 %/bit) — o ganho real sobre a property, que a
  /// coleta lê a cada 10 s.
  static const String soc = 'BMSH_BattSOC';

  /// Tensão do pack, calibrada (0,1 V/bit).
  static const String packVolts = 'BMSH_BattVolt';

  /// Corrente do pack. Quando o schema ainda não traz calibração, a conversão
  /// documentada da tela de carga continua sendo explicitamente uma estimativa.
  static const String packCurrent = 'BMSH_BattCurr';

  /// Potência de tração calibrada pelo Roadcast e validada no carro.
  static const String drivePower = 'VCU_DrvPwrAct';

  /// Inclinação longitudinal atual da via. O schema Roadcast publica o valor
  /// físico calibrado em graus; a tela não deve recalcular o cru localmente.
  static const String roadIncline = 'ESC_RoadInclnRoadIncln';

  static const String pedal = 'VCU_AccelPedalPosition';
  static const String pedalInvalid = 'VCU_AccelPedalPositionInvalid';

  static const String regenTorque = 'VCU_RegenTrqAct';
  static const String regenLevel = 'VCU_ePTRegencyLevInd';

  static const String brake = 'ESC_BrakePedalSwitchStatus';
  static const String brakeInvalid = 'ESC_BrakePedalSwitchInvalid';

  static const String speed = 'ESC_VehicleSpeed';
  static const String speedInvalid = 'ESC_VehicleSpeedInvalid';

  /// Candidatos de diagnóstico. Permanecem crus até a captura controlada fechar
  /// escala e semântica contra a property exibida pelo painel.
  static const String averageConsumption = 'VCU_PwrCnsAvg';
  static const String averageConsumption1 = 'VCU_PwrCnsAvg1';

  /// Coincidiu 1:1 com PERF_ODOMETER em uma captura estacionária. Ainda fica cru
  /// até uma captura em movimento confirmar unidade, rollover e cadência.
  static const String totalOdometer = 'IPK_IPKTotalOdometer';

  /// Ordem em que o lote é pedido — e, portanto, a ordem em que
  /// [LiveTripCanState.observe] espera a leitura de volta.
  static const List<String> watchlist = [
    soc,
    packVolts,
    packCurrent,
    drivePower,
    roadIncline,
    pedal,
    pedalInvalid,
    regenTorque,
    regenLevel,
    brake,
    brakeInvalid,
    speed,
    speedInvalid,
    averageConsumption,
    averageConsumption1,
    totalOdometer,
  ];
}

/// Fundo de escala do pedal cru (8 bits). Só alimenta a barra; o número mostrado
/// continua sendo o cru, porque a escala em % não está confirmada.
const int kPedalRawFullScale = 255;

/// Estado ao vivo dos sinais CAN da tela de trip.
///
/// É uma casca semântica sobre [CanActivityTracker]: o tracker cuida de detecção de
/// mudança, taxa e histórico para sparkline; aqui em cima cada getter diz o que o
/// sinal significa e, principalmente, **quando não dá para usá-lo** — inválido pelo
/// bit do barramento, ou sem escala confirmada.
///
/// Puro Dart: recebe [CanBridgeReading] já pronta, então a lógica é testável sem
/// carro, sem daemon e sem FFI.
class LiveTripCanState {
  LiveTripCanState({
    required List<RoadcastSchemaEntry> entries,
    bool retainActivityHistory = true,
  }) : tracker = CanActivityTracker(
         entries: entries,
         retainHistory: retainActivityHistory,
         trackRate: retainActivityHistory,
       ) {
    for (final signal in tracker.signals) {
      _byName[signal.name] = signal;
    }
  }

  final CanActivityTracker tracker;
  final Map<String, CanSignalActivity> _byName = {};
  final EcoCoachEngine _ecoCoach = EcoCoachEngine();
  EcoCoachSnapshot _ecoCoachSnapshot = const EcoCoachSnapshot.empty();
  double? _ecoSpeedKmh;

  void observe(CanBridgeReading reading, int nowMs) {
    const ecoInputs = <String>[
      LiveTripCanNames.drivePower,
      LiveTripCanNames.pedal,
      LiveTripCanNames.brake,
    ];
    final previousTimestamps = <String, int?>{
      for (final name in ecoInputs) name: _byName[name]?.lastChangeTsNs,
    };
    tracker.observe(reading, nowMs);
    final anyInputChanged = ecoInputs.any(
      (name) => _byName[name]?.lastChangeTsNs != previousTimestamps[name],
    );
    if (anyInputChanged && _ecoSpeedKmh != null) {
      _ecoCoachSnapshot = _ecoCoach.observe(
        EcoCoachInput(
          timestamp: Duration(milliseconds: nowMs),
          motionSampleChanged: false,
          speedKmh: _ecoSpeedKmh,
          drivePowerKw: drivePowerKw,
          pedalFraction: pedalFraction,
          brakePressed: brakePressed,
        ),
      );
    }
  }

  /// Alimenta o Eco Coach com a mesma VEHICLE_SPEED do CarPropertyManager usada
  /// no Room. Roadcast continua fornecendo apenas demanda, pedal e freio.
  void observeVehicleSpeed({
    required double? speedKmh,
    required int nowMs,
    required int motionTimestampNanos,
  }) {
    _ecoSpeedKmh = speedKmh;
    _ecoCoachSnapshot = _ecoCoach.observe(
      EcoCoachInput(
        timestamp: Duration(milliseconds: nowMs),
        motionTimestamp: Duration(microseconds: motionTimestampNanos ~/ 1000),
        speedKmh: speedKmh,
        drivePowerKw: drivePowerKw,
        pedalFraction: pedalFraction,
        brakePressed: brakePressed,
      ),
    );
  }

  CanSignalActivity? signal(String name) => _byName[name];

  /// Verdadeiro quando o sinal existe, está válido e o companheiro `Invalid` não
  /// está levantado.
  bool isUsable(String name, {String? invalidCompanion}) {
    final target = _byName[name];
    if (target == null || !target.valid) return false;
    if (invalidCompanion == null) return true;
    final invalid = _byName[invalidCompanion];
    // Sem a leitura do bit de validade não há como afirmar que o valor presta;
    // tratar ausência como "válido" é justamente o otimismo que some com a falha.
    if (invalid == null || !invalid.valid) return false;
    return invalid.raw == 0;
  }

  /// Valor físico, só para sinal calibrado e válido.
  ///
  /// Sem escala confirmada o "valor físico" é o cru multiplicado por um palpite, e
  /// devolver isso como medição é o erro que este projeto evita por escrito.
  double? calibratedValue(String name, {String? invalidCompanion}) {
    if (!isUsable(name, invalidCompanion: invalidCompanion)) return null;
    final target = _byName[name]!;
    return target.calibrated ? target.value : null;
  }

  int? rawValue(String name, {String? invalidCompanion}) {
    if (!isUsable(name, invalidCompanion: invalidCompanion)) return null;
    return _byName[name]!.raw;
  }

  /// O sinal como [Measurement]: o número e o motivo de ele valer, juntos.
  ///
  /// As quatro saídas não são graus de qualidade, são fatos diferentes sobre o
  /// barramento. Ausente do schema e parado com o bit `Invalid` levantado
  /// imprimem o mesmo `--`, e é justamente por isso que precisam continuar
  /// distinguíveis: uma é um sinal que este carro não publica, a outra é um ECU
  /// dizendo que a leitura de agora não presta.
  ///
  /// Sem [scale] não há queda para o cru: sinal sem escala publicada é ausência,
  /// nunca um cru multiplicado por um palpite.
  Measurement _measurement(
    String name, {
    required String unit,
    String? invalidCompanion,
    double? scale,
    int zeroCount = 0,
    String estimateNote = '',
  }) {
    final target = _byName[name];
    if (target == null) {
      return Measurement.unreported(
        unit: unit,
        note: 'fora do schema negociado',
      );
    }
    if (!target.valid) return Measurement.invalid(unit: unit);
    if (invalidCompanion != null) {
      final companion = _byName[invalidCompanion];
      // Sem a leitura do bit não há como afirmar que o valor presta; tratar
      // ausência como "válido" é o otimismo que some com a falha.
      if (companion == null || !companion.valid) {
        return Measurement.unreported(
          unit: unit,
          note: 'bit de validade $invalidCompanion ausente',
        );
      }
      if (companion.raw != 0) {
        return Measurement.invalid(
          unit: unit,
          note: '$invalidCompanion levantado',
        );
      }
    }
    if (target.calibrated) {
      return Measurement.measured(target.value, unit: unit);
    }
    if (scale == null) {
      return Measurement.unreported(unit: unit, note: 'sem escala publicada');
    }
    return Measurement.estimated(
      (target.raw - zeroCount) * scale,
      unit: unit,
      note: estimateNote,
    );
  }

  bool? boolValue(String name, {String? invalidCompanion}) {
    final raw = rawValue(name, invalidCompanion: invalidCompanion);
    return raw == null ? null : raw != 0;
  }

  List<double> historyOf(String name) =>
      _byName[name]?.history ?? const <double>[];

  // --- Leituras semânticas -------------------------------------------------

  /// SOC do pack em %, com 0,1 de resolução.
  double? get socPercent => calibratedValue(LiveTripCanNames.soc);

  double? get packVoltage => calibratedValue(LiveTripCanNames.packVolts);

  /// Corrente do pack em ampères, com o motivo de ela valer.
  ///
  /// Prefere a calibração negociada; em schemas antigos usa
  /// `(raw − 5000) × 0,1`, e nesse caso sai como [MeasurementValidity.estimated].
  /// A UI não precisa lembrar de marcar `EST`: ela lê
  /// [Measurement.needsEstimateBadge] do próprio valor.
  Measurement get packCurrent => _measurement(
    LiveTripCanNames.packCurrent,
    unit: 'A',
    scale: kBattCurrentScaleAPerBit,
    zeroCount: kBattCurrentAssumedZero,
    estimateNote: 'zero assumido de $kBattCurrentAssumedZero contagens',
  );

  double? get packCurrentA => packCurrent.displayValue;

  /// Potência de tração em kW, somente quando o Roadcast a publica calibrada.
  double? get drivePowerKw => calibratedValue(LiveTripCanNames.drivePower);

  /// Inclinação atual em porcento, somente com os bits de validade e
  /// calibração publicados pelo Roadcast. Sem isso a dash mostra ausência,
  /// nunca o cru.
  ///
  /// A unidade é porcento, não graus: contra o declive que a altitude GPS dá,
  /// o ajuste sobe até 0,90 conforme o filtro aperta, e graus preveem 0,573.
  double? get roadInclinePercent =>
      calibratedValue(LiveTripCanNames.roadIncline);

  /// A mesma inclinação como ângulo, para um desenho que precisa girar.
  ///
  /// Isto é geometria sobre o valor já calibrado, não uma segunda decodificação:
  /// porcento é a tangente do ângulo vezes 100, então o ângulo é `atan(p/100)`.
  /// A regra que proíbe recalcular o cru continua valendo — se o daemon não
  /// publicar escala, [roadInclinePercent] é nulo e isto também é.
  ///
  /// A diferença importa na tela: a ±22,6 % que este barramento alcança, tratar
  /// porcento como grau erra por quase 5°.
  double? get roadInclineDegrees {
    final percent = roadInclinePercent;
    if (percent == null) return null;
    return math.atan(percent / 100.0) * 180.0 / math.pi;
  }

  int? get pedalRaw => rawValue(
    LiveTripCanNames.pedal,
    invalidCompanion: LiveTripCanNames.pedalInvalid,
  );

  /// Fração para a barra do pedal, do cru sobre o fundo de escala de 8 bits.
  double? get pedalFraction {
    final raw = pedalRaw;
    if (raw == null) return null;
    return (raw / kPedalRawFullScale).clamp(0.0, 1.0);
  }

  int? get regenTorqueRaw => rawValue(LiveTripCanNames.regenTorque);

  int? get regenLevel => rawValue(LiveTripCanNames.regenLevel);

  bool? get brakePressed => boolValue(
    LiveTripCanNames.brake,
    invalidCompanion: LiveTripCanNames.brakeInvalid,
  );

  int? get speedRaw => rawValue(
    LiveTripCanNames.speed,
    invalidCompanion: LiveTripCanNames.speedInvalid,
  );

  /// Candidato CAN mantido só para diagnóstico; não alimenta mais a tela nem o
  /// Eco Coach porque sua decodificação não corresponde à velocidade do carro.
  ///
  /// Passa pelo companheiro `ESC_VehicleSpeedInvalid`, então distingue três
  /// coisas que o `double?` antigo achatava em `null`: o ECU dizendo que a
  /// leitura não presta, o bit de validade não estar no barramento, e o sinal
  /// não ter escala publicada.
  Measurement get speed => _measurement(
    LiveTripCanNames.speed,
    unit: 'km/h',
    invalidCompanion: LiveTripCanNames.speedInvalid,
  );

  double? get speedKmh => speed.displayValue;

  EcoCoachSnapshot get ecoCoach => _ecoCoachSnapshot;

  int? get averageConsumptionRaw =>
      rawValue(LiveTripCanNames.averageConsumption);

  int? get averageConsumption1Raw =>
      rawValue(LiveTripCanNames.averageConsumption1);

  int? get totalOdometerRaw => rawValue(LiveTripCanNames.totalOdometer);

  /// Conversão provisória 1 raw = 1 km, isolada para nunca parecer calibração.
  /// A UI que a consumir deve exibir EST até a captura em movimento fechar a
  /// equivalência contra PERF_ODOMETER.
  double? get estimatedTotalOdometerKm => totalOdometerRaw?.toDouble();
}

/// Mede a escala de um sinal cru dividindo uma referência confiável pelo cru.
///
/// Existe porque a escala de vários sinais deste barramento não está no binário do
/// VHAL: foi deduzida. Quando há uma segunda fonte para a mesma grandeza — a
/// property do VHAL, que a coleta já lê — a razão entre as duas *é* a escala, e
/// medi-la ao vivo é a diferença entre confirmar o palpite e continuar chutando.
///
/// A mediana, e não a média, porque as duas fontes não são simultâneas: durante uma
/// aceleração forte o cru do CAN já subiu e a property ainda não, o que produz
/// razões absurdas que uma média carregaria para sempre.
class ImpliedScale {
  ImpliedScale({this.window = 96});

  /// Quantas razões recentes entram na mediana.
  final int window;

  /// Abaixo disto a quantização domina: a 2 km/h, um passo de arredondamento na
  /// referência muda a razão em dezenas de por cento.
  static const double _minReference = 5.0;
  static const int _minRaw = 8;

  final List<double> _ratios = <double>[];

  int get sampleCount => _ratios.length;

  void observe({required int raw, required double reference}) {
    if (raw < _minRaw || reference < _minReference) return;
    _ratios.add(reference / raw);
    if (_ratios.length > window) _ratios.removeAt(0);
  }

  /// Escala implícita (unidade da referência por bit), ou null sem amostras.
  double? get scale {
    if (_ratios.isEmpty) return null;
    final sorted = List<double>.of(_ratios)..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }

  void reset() => _ratios.clear();
}
