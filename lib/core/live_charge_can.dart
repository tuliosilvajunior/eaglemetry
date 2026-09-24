import 'package:telemetry_core/telemetry_core.dart';

import 'can_activity.dart';
import 'can_bridge_models.dart';

/// Nomes CAN que a tela live de carga observa.
///
/// Curta pelo mesmo motivo da lista de viagem: cada leitura em lote é uma travessia
/// FFI para o conjunto todo, e o que serve para garimpar o barramento é a tela Trace.
abstract final class LiveChargeCanNames {
  /// SOC do pack, calibrado (0,1 %/bit). Envelhece no barramento — ver
  /// [LiveChargeCanState.socPercent].
  static const String soc = 'BMSH_BattSOC';

  /// Tensão do pack, calibrada (0,1 V/bit).
  static const String packVolts = 'BMSH_BattVolt';

  /// Corrente do pack. **Crua**: o Roadcast não publica escala para ela.
  /// Ver [LiveChargeCanState.packCurrentA].
  static const String packCurrent = 'BMSH_BattCurr';

  /// Tensão e corrente na entrada do OBC (a tomada), escala 0,1 confirmada
  /// contra as properties `DCHA_*` em 2026-07-26.
  static const String obcInputVolts = 'OBC_uInAct';
  static const String obcInputCurrent = 'OBC_iInAct';

  /// Estado do carregador de bordo. Cru: 4 = carregando, medido no carro.
  static const String obcState = 'OBC_ChrgrSt';

  /// Ordem em que o lote é pedido — e, portanto, a ordem em que
  /// [LiveChargeCanState.observe] espera a leitura de volta.
  static const List<String> watchlist = [
    soc,
    packVolts,
    packCurrent,
    obcInputVolts,
    obcInputCurrent,
    obcState,
  ];
}

/// Escala de [LiveChargeCanNames.packCurrent], em ampères por bit.
///
/// Determinada testando as codificações candidatas contra a física: com o pacote a 402,7 V e 1,039 kW entrando pela
/// tomada, só 0,1 A/bit sobrevive (as vizinhas dão 41 % e >100 % de rendimento no
/// OBC). A escala está fechada; o zero não.
const double kBattCurrentScaleAPerBit = 0.1;

/// Escala do par de entrada do OBC, em unidade por bit.
///
/// Confirmada, não deduzida: em 26/07 os crus `OBC_uInAct = 2165` e
/// `OBC_iInAct = 48` bateram exatamente com as properties `DCHA_CHARGE_ACDC_VOLT`
/// (216,5 V) e `DCHA_CHARGE_ACDC_CURRENT` (4,8 A). Só entra em uso quando o
/// daemon não publica o sinal já calibrado.
const double kObcInputScale = 0.1;

/// Zero **hipotético** de [LiveChargeCanNames.packCurrent].
///
/// Entrou como hipótese e passou no teste de coerência do mesmo documento, mas nunca
/// foi medido: medir exige o carro acordado, desconectado e sem corrente. Se o zero
/// real for 4995, a escala não muda e toda corrente sai deslocada em 0,5 A — por isso
/// [LiveChargeCanState.currentZero] mede o zero observado ao vivo, e por isso o valor
/// em ampères aparece na tela marcado como estimativa.
///
/// A viagem de calibração de 02/08/2026 fechou a **escala e o sinal**, não o zero:
/// a regressão da corrente contra a tração tem intercepto de −0,65 A, e esse
/// intercepto mistura o zero com a carga auxiliar. As duas fontes ainda
/// discordam — o rendimento do OBC medido em três cargas implica zero perto de
/// 4999, enquanto o DBC do Roadcast usa 5005. São 0,6 A em aberto.
const int kBattCurrentAssumedZero = 5000;

/// Idade acima da qual um sinal do BMS deixa de descrever o instante.
///
/// `BMSH_BattVolt` e `BMSH_BattSOC` envelhecem no barramento enquanto
/// `BMSH_BattCurr` continua em dezenas de ms (documento de 26/07 §6): dois sinais do
/// mesmo módulo, um vivo e dois parados, no mesmo instante. Sem este corte a tela
/// mostraria a tensão de dois minutos atrás como se fosse a de agora.
const Duration kBattSignalMaxAge = Duration(seconds: 5);

enum LiveChargeInputSide { obc, pack }

/// Electrical values that represent the charger input for the active plug.
///
/// In AC the charger input is the wall-side OBC pair. In DC the OBC is bypassed,
/// so its values legitimately stay at zero and the only meaningful input values
/// exposed by Roadcast are the pack voltage/current and their V×I product.
class LiveChargeInputReadings {
  const LiveChargeInputReadings({
    required this.side,
    required this.voltageV,
    required this.currentA,
    required this.powerKw,
  });

  final LiveChargeInputSide side;
  final double? voltageV;
  final double? currentA;
  final double? powerKw;
}

/// Estado ao vivo dos sinais CAN da tela de carga.
///
/// Casca semântica sobre [CanActivityTracker], como o equivalente de viagem em
/// `live_trip_can.dart`: o tracker cuida de detecção de mudança, taxa e histórico;
/// aqui cada getter diz o que o sinal significa e **quando não dá para usá-lo**.
///
/// Puro Dart: recebe [CanBridgeReading] já pronta, então a lógica é testável sem
/// carro, sem daemon e sem FFI.
class LiveChargeCanState {
  LiveChargeCanState({
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

  /// Zero observado de [LiveChargeCanNames.packCurrent]; ver [ZeroObserver].
  final ZeroObserver currentZero = ZeroObserver();

  int _nowMs = 0;

  void observe(CanBridgeReading reading, int nowMs) {
    _nowMs = nowMs;
    tracker.observe(reading, nowMs);
  }

  CanSignalActivity? signal(String name) => _byName[name];

  bool isUsable(String name) => _byName[name]?.valid ?? false;

  /// Verdadeiro quando o sinal está válido **e** mudou dentro de
  /// [kBattSignalMaxAge]. Sinal que nunca mudou desde a abertura da tela conta como
  /// fresco: a linha de base ainda não teve tempo de envelhecer.
  bool isFresh(String name) {
    final target = _byName[name];
    if (target == null || !target.valid) return false;
    final age = target.ageSince(_nowMs);
    return age == null || age <= kBattSignalMaxAge;
  }

  /// Valor físico, só para sinal calibrado, válido e fresco.
  double? calibratedValue(String name) {
    final target = _byName[name];
    if (target == null || !isFresh(name)) return null;
    return target.calibrated ? target.value : null;
  }

  /// Verdadeiro quando o próprio Roadcast publica escala para o sinal.
  ///
  /// É a diferença entre medição e estimativa nesta tela: com escala do daemon o
  /// número vale por si; sem ela, o que existe é a hipótese documentada, e a tela
  /// tem que dizer isso.
  bool isCalibrated(String name) => _byName[name]?.calibrated ?? false;

  int? rawValue(String name) {
    final target = _byName[name];
    if (target == null || !isUsable(name)) return null;
    return target.raw;
  }

  /// Valor calibrado quando o daemon o publica; senão o cru convertido pela
  /// escala [scale] e pelo zero [zeroCount].
  double? _scaledValue(
    String name, {
    required double scale,
    int zeroCount = 0,
  }) => _measurement(
    name,
    unit: '',
    scale: scale,
    zeroCount: zeroCount,
  ).displayValue;

  /// O sinal como [Measurement]: o número e o motivo de ele valer, juntos.
  ///
  /// Este é o caminho único. Os getters `double?` abaixo continuam existindo
  /// para quem só quer plotar, mas quem desenha na tela lê o [Measurement],
  /// porque é o que carrega a diferença entre medição e estimativa sem exigir
  /// que o call site lembre de consultar um booleano ao lado.
  ///
  /// Sem [scale] não há queda para o cru: sinal sem escala publicada é ausência,
  /// nunca um cru multiplicado por um palpite.
  Measurement _measurement(
    String name, {
    required String unit,
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
    if (!isFresh(name)) {
      return Measurement.unreported(
        unit: unit,
        note: 'parado há mais de ${kBattSignalMaxAge.inSeconds} s',
      );
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

  List<double> historyOf(String name) =>
      _byName[name]?.history ?? const <double>[];

  // --- Leituras semânticas -------------------------------------------------

  /// SOC do pack em %, com 0,1 de resolução, ou null quando o CAN o entregou
  /// velho. A tela cai para a property do VHAL nesse caso.
  double? get socPercent => calibratedValue(LiveChargeCanNames.soc);

  Measurement get packVoltage =>
      _measurement(LiveChargeCanNames.packVolts, unit: 'V');

  double? get packVoltageV => packVoltage.displayValue;

  /// Cru da corrente do pack, sem conversão. É o número auditável.
  int? get packCurrentRaw => rawValue(LiveChargeCanNames.packCurrent);

  /// Corrente do pack em ampères, com o motivo de ela valer.
  ///
  /// Negativo = entrando no pacote, a convenção medida durante a carga de 26/07.
  ///
  /// Quando o Roadcast publica o sinal calibrado, o valor é dele — sem zero
  /// assumido no caminho, e sai como [MeasurementValidity.measured]. Quando não
  /// publica, cai para a hipótese documentada (`(cru − 5000) × 0,1`) e sai como
  /// [MeasurementValidity.estimated], que é o que obriga a tela a marcar `EST`.
  Measurement get packCurrent => _measurement(
    LiveChargeCanNames.packCurrent,
    unit: 'A',
    scale: kBattCurrentScaleAPerBit,
    zeroCount: kBattCurrentAssumedZero,
    estimateNote: 'zero assumido de $kBattCurrentAssumedZero contagens',
  );

  double? get packCurrentA => packCurrent.displayValue;

  /// A mesma corrente com o zero **observado** no lugar do assumido, ou null
  /// enquanto não houver observação suficiente. Existe para dar ao usuário a
  /// diferença entre a hipótese e a medida, lado a lado.
  double? get packCurrentObservedA {
    final raw = packCurrentRaw;
    final zero = currentZero.zero;
    if (raw == null || zero == null) return null;
    return (raw - zero) * kBattCurrentScaleAPerBit;
  }

  /// Potência **no pacote**, por V×I do lado DC.
  ///
  /// Herda a confiança da corrente: medição quando o daemon a calibra, estimativa
  /// quando o valor vem da hipótese do zero. [Measurement.combine] faz isso por
  /// construção, então a herança não depende de ninguém lembrar dela.
  Measurement get packPower => Measurement.combine(
    packVoltage,
    packCurrent,
    unit: 'kW',
    compute: (volts, amps) => volts * amps / 1000,
  );

  double? get packPowerKw => packPower.displayValue;

  /// Tensão na entrada do OBC (a parede). Escala 0,1 confirmada contra
  /// `DCHA_CHARGE_ACDC_VOLT` em 26/07.
  double? get obcInputVoltsV =>
      _scaledValue(LiveChargeCanNames.obcInputVolts, scale: kObcInputScale);

  /// Corrente na entrada do OBC (a parede). Escala 0,1 confirmada contra
  /// `DCHA_CHARGE_ACDC_CURRENT` em 26/07.
  double? get obcInputCurrentA =>
      _scaledValue(LiveChargeCanNames.obcInputCurrent, scale: kObcInputScale);

  /// Potência saindo da parede, por V×I do lado AC.
  double? get obcInputPowerKw {
    final volts = obcInputVoltsV;
    final amps = obcInputCurrentA;
    if (volts == null || amps == null) return null;
    return volts * amps / 1000;
  }

  LiveChargeInputReadings inputReadings({required bool isDc}) {
    if (isDc) {
      return LiveChargeInputReadings(
        side: LiveChargeInputSide.pack,
        voltageV: packVoltageV,
        currentA: packCurrentA?.abs(),
        powerKw: packPowerKw?.abs(),
      );
    }
    return LiveChargeInputReadings(
      side: LiveChargeInputSide.obc,
      voltageV: obcInputVoltsV,
      currentA: obcInputCurrentA?.abs(),
      powerKw: obcInputPowerKw?.abs(),
    );
  }

  int? get obcStateRaw => rawValue(LiveChargeCanNames.obcState);

  /// **Rendimento da carga em tempo real**: o que chega ao pacote sobre o que sai
  /// da parede.
  ///
  /// `(BMSH_BattVolt × BMSH_BattCurr) / (OBC_uInAct × OBC_iInAct)`, as duas
  /// metades medidas no mesmo instante do mesmo lote FFI — o que importa, porque
  /// comparar um lado de agora com o outro de dois segundos atrás produz um
  /// rendimento que oscila sem que o carregador tenha mudado nada.
  ///
  /// Null com a carga parada: abaixo de [_minEfficiencyInputKw] o denominador é
  /// pequeno demais e a razão vira ruído amplificado. Acima de 1 o resultado é
  /// impossível (mais energia chegando do que saiu), e é assim que um zero errado
  /// de `BMSH_BattCurr` se denuncia — a tela mostra o valor em vez de escondê-lo.
  double? get obcEfficiency {
    final input = obcInputPowerKw;
    final pack = packPowerKw;
    if (input == null || pack == null) return null;
    if (input < _minEfficiencyInputKw) return null;
    return pack.abs() / input;
  }

  /// Perda no carregador, em kW: a diferença entre as duas potências.
  double? get obcLossKw {
    final input = obcInputPowerKw;
    final pack = packPowerKw;
    if (input == null || pack == null) return null;
    if (input < _minEfficiencyInputKw) return null;
    return input - pack.abs();
  }

  /// Abaixo disto o rendimento é ruído: com 50 W entrando, 10 W de erro em
  /// qualquer das metades move a razão em 20 pontos percentuais.
  static const double _minEfficiencyInputKw = 0.1;

  /// Alimenta o medidor de zero quando não há corrente circulando.
  ///
  /// [charging] vem do estado da sessão, não do próprio sinal: usar a corrente para
  /// decidir se há corrente é circular, e é como um zero errado se confirmaria
  /// sozinho.
  void observeCurrentZero({required bool charging}) {
    if (charging) return;
    final raw = packCurrentRaw;
    if (raw == null) return;
    currentZero.observe(raw);
  }
}

/// Mede o zero de um sinal cru acumulando leituras feitas quando a grandeza é
/// sabidamente nula.
///
/// A mediana, e não a média, porque uma única amostra colhida no instante em que a
/// carga começou é um valor de carga cheia entrando numa lista de zeros, e a média a
/// carregaria para sempre.
class ZeroObserver {
  ZeroObserver({this.window = 256});

  /// Quantas leituras recentes entram na mediana.
  final int window;

  /// Abaixo disto a mediana ainda é ruído de poucas amostras.
  static const int minSamples = 30;

  final List<int> _samples = <int>[];

  int get sampleCount => _samples.length;

  void observe(int raw) {
    _samples.add(raw);
    if (_samples.length > window) _samples.removeAt(0);
  }

  /// Zero observado, ou null enquanto não houver [minSamples].
  double? get zero {
    if (_samples.length < minSamples) return null;
    final sorted = List<int>.of(_samples)..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle].toDouble();
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }

  /// Distância entre o zero observado e o assumido, em ampères. É o erro que a
  /// leitura em ampères carrega hoje.
  double? get offsetErrorA {
    final observed = zero;
    if (observed == null) return null;
    return (observed - kBattCurrentAssumedZero) * kBattCurrentScaleAPerBit;
  }

  void reset() => _samples.clear();
}
