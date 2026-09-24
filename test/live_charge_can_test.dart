import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/can_bridge_models.dart';
import 'package:capy_energy/core/live_charge_can.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// Entrada do schema. `calibrated` é o bit 0x02 dos flags: é ele que separa
/// medição de estimativa nesta tela.
RoadcastSchemaEntry _entry({
  required int index,
  required String name,
  required int canId,
  required String unit,
  bool calibrated = true,
}) => RoadcastSchemaEntry(
  stableId: index,
  index: index,
  invalidSignalIndex: null,
  canId: canId,
  kind: 2,
  source: 1,
  width: 16,
  flags: calibrated ? 0x02 : 0x00,
  scale: 1,
  offset: 0,
  name: name,
  unit: unit,
);

/// Schema na ordem de [LiveChargeCanNames.watchlist], que é o contrato
/// posicional da leitura em lote.
List<RoadcastSchemaEntry> _schema({bool currentCalibrated = false}) => [
  _entry(index: 0, name: LiveChargeCanNames.soc, canId: 0x17A, unit: '%'),
  _entry(index: 1, name: LiveChargeCanNames.packVolts, canId: 0x178, unit: 'V'),
  _entry(
    index: 2,
    name: LiveChargeCanNames.packCurrent,
    canId: 0x250,
    unit: currentCalibrated ? 'A' : '',
    calibrated: currentCalibrated,
  ),
  _entry(
    index: 3,
    name: LiveChargeCanNames.obcInputVolts,
    canId: 0x2A0,
    unit: 'V',
  ),
  _entry(
    index: 4,
    name: LiveChargeCanNames.obcInputCurrent,
    canId: 0x2A0,
    unit: 'A',
  ),
  _entry(
    index: 5,
    name: LiveChargeCanNames.obcState,
    canId: 0x2A0,
    unit: '',
    calibrated: false,
  ),
];

CanBridgeReading _reading({
  required List<double> values,
  required List<int> raws,
  required List<int> tsNs,
  List<bool>? calibrated,
}) => CanBridgeReading(
  values: Float32List.fromList(values),
  raws: Uint32List.fromList(raws),
  timestampsNs: Int64List.fromList(tsNs),
  flags: Uint8List.fromList([
    for (var i = 0; i < values.length; i++)
      0x01 | ((calibrated == null || calibrated[i]) ? 0x02 : 0x00),
  ]),
);

/// Leitura da carga AC medida no carro em 2026-07-26: pacote a 402,7 V,
/// 216,5 V x 4,8 A na tomada, `BMSH_BattCurr` cru em 4979.
CanBridgeReading _measuredCharge({
  int currentRaw = 4979,
  double currentValue = 0,
  bool currentCalibrated = false,
  int tick = 1,
}) => _reading(
  values: [64.8, 402.7, currentValue, 216.5, 4.8, 4],
  raws: [648, 4027, currentRaw, 2165, 48, 4],
  tsNs: [tick, tick, tick, tick, tick, tick],
  calibrated: [true, true, currentCalibrated, true, true, false],
);

void main() {
  group('corrente do pacote', () {
    test('usa a escala do daemon quando ele publica o sinal calibrado', () {
      final can = LiveChargeCanState(entries: _schema(currentCalibrated: true));

      can.observe(
        _measuredCharge(currentValue: -2.1, currentCalibrated: true),
        1000,
      );

      expect(can.packCurrent.isMeasured, isTrue);
      expect(can.packCurrentA, closeTo(-2.1, 0.001));
    });

    test('cai para a hipótese documentada quando não há escala publicada', () {
      final can = LiveChargeCanState(entries: _schema());

      can.observe(_measuredCharge(), 1000);

      expect(can.packCurrent.needsEstimateBadge, isTrue);
      // (4979 - 5000) x 0,1 = -2,1 A, o valor que fecha o rendimento do OBC em
      // 81% na captura de 26/07 §5.
      expect(can.packCurrentA, closeTo(-2.1, 0.001));
      expect(can.packCurrentRaw, 4979);
    });

    test('negativo é corrente entrando no pacote', () {
      final can = LiveChargeCanState(entries: _schema());

      can.observe(_measuredCharge(currentRaw: 4200), 1000);

      expect(can.packCurrentA, lessThan(0));
    });
  });

  group('rendimento em tempo real', () {
    test('é a potência do pacote sobre a da parede', () {
      final can = LiveChargeCanState(entries: _schema());

      can.observe(_measuredCharge(), 1000);

      // Parede: 216,5 x 4,8 = 1,0392 kW. Pacote: 402,7 x 2,1 = 0,8457 kW.
      expect(can.obcInputPowerKw, closeTo(1.0392, 0.001));
      expect(can.packPowerKw!.abs(), closeTo(0.8457, 0.001));
      expect(can.obcEfficiency, closeTo(0.8137, 0.001));
      expect(can.obcLossKw, closeTo(0.1935, 0.001));
    });

    test('não existe com a carga parada, onde a razão seria ruído', () {
      final can = LiveChargeCanState(entries: _schema());

      can.observe(
        _reading(
          values: [64.8, 402.7, 0, 0, 0, 0],
          raws: [648, 4027, 5000, 0, 0, 0],
          tsNs: [1, 1, 1, 1, 1, 1],
          calibrated: [true, true, false, true, true, false],
        ),
        1000,
      );

      expect(can.obcEfficiency, isNull);
      expect(can.obcLossKw, isNull);
    });

    test('acima de 100% aparece, porque denuncia um zero errado', () {
      final can = LiveChargeCanState(entries: _schema());

      // Cru bem abaixo do zero assumido: corrente grande demais para a potência
      // que a tomada entrega.
      can.observe(_measuredCharge(currentRaw: 4900), 1000);

      expect(can.obcEfficiency, greaterThan(1.0));
    });
  });

  group('lado elétrico apresentado pela tela', () {
    test('carga AC usa tensão, corrente e potência do OBC', () {
      final can = LiveChargeCanState(entries: _schema());
      can.observe(_measuredCharge(), 1000);

      final input = can.inputReadings(isDc: false);

      expect(input.voltageV, closeTo(216.5, 0.001));
      expect(input.currentA, closeTo(4.8, 0.001));
      expect(input.powerKw, closeTo(1.0392, 0.001));
      expect(input.side, LiveChargeInputSide.obc);
    });

    test('carga DC ignora zeros do OBC e usa o lado do pacote', () {
      final can = LiveChargeCanState(entries: _schema());
      can.observe(
        _reading(
          values: [64.8, 402.7, -120.0, 0, 0, 0],
          raws: [648, 4027, 3800, 0, 0, 0],
          tsNs: [1, 1, 1, 1, 1, 1],
          calibrated: [true, true, true, true, true, false],
        ),
        1000,
      );

      final input = can.inputReadings(isDc: true);

      expect(input.voltageV, closeTo(402.7, 0.001));
      expect(input.currentA, closeTo(120.0, 0.001));
      expect(input.powerKw, closeTo(48.324, 0.001));
      expect(input.side, LiveChargeInputSide.pack);
    });
  });

  group('frescor', () {
    test('sinal do BMS que parou de mudar deixa de ser apresentado', () {
      final can = LiveChargeCanState(entries: _schema());

      // Duas leituras com carimbos distintos estabelecem a última mudança...
      can.observe(_measuredCharge(tick: 1), 1000);
      can.observe(_measuredCharge(tick: 2), 2000);
      expect(can.packVoltageV, closeTo(402.7, 0.001));

      // ...e a partir dela o tempo corre. O carimbo do daemon não avança mais,
      // que é o caso documentado em 26/07 §6: BattVolt e BattSOC envelhecem
      // enquanto BattCurr continua vivo.
      can.observe(
        _measuredCharge(tick: 2),
        2000 + kBattSignalMaxAge.inMilliseconds + 1,
      );

      expect(can.packVoltageV, isNull);
      expect(can.socPercent, isNull);
    });
  });

  group('ZeroObserver', () {
    test('não responde antes de ter amostras suficientes', () {
      final observer = ZeroObserver();

      for (var i = 0; i < ZeroObserver.minSamples - 1; i++) {
        observer.observe(4998);
      }

      expect(observer.zero, isNull);
      expect(observer.offsetErrorA, isNull);
    });

    test('mediana ignora a amostra isolada colhida fora de repouso', () {
      final observer = ZeroObserver();

      for (var i = 0; i < ZeroObserver.minSamples; i++) {
        observer.observe(4998);
      }
      observer.observe(3000); // um instante de carga entrando na janela

      expect(observer.zero, 4998);
      // 4998 contra o zero assumido de 5000: -0,2 A de erro em toda leitura.
      expect(observer.offsetErrorA, closeTo(-0.2, 0.001));
    });

    test('só acumula com a sessão parada', () {
      final can = LiveChargeCanState(entries: _schema());
      can.observe(_measuredCharge(), 1000);

      for (var i = 0; i < ZeroObserver.minSamples; i++) {
        can.observeCurrentZero(charging: true);
      }
      expect(can.currentZero.sampleCount, 0);

      for (var i = 0; i < ZeroObserver.minSamples; i++) {
        can.observeCurrentZero(charging: false);
      }
      expect(can.currentZero.sampleCount, ZeroObserver.minSamples);
      expect(can.currentZero.zero, 4979);
    });
  });

  group('o motivo de um valor não valer', () {
    test('sinal fora do schema negociado sai como não reportado', () {
      // O carro não publica este sinal. Não é uma leitura ruim: é a ausência
      // de leitura, e a diferença importa para saber se vale procurar o
      // defeito no daemon ou no barramento.
      final can = LiveChargeCanState(
        entries: _schema()
            .where((entry) => entry.name != LiveChargeCanNames.packCurrent)
            .toList(),
      );

      expect(
        can.packCurrent.validity,
        MeasurementValidity.unreported,
        reason: 'ausente do schema não é o mesmo que inválido',
      );
      expect(can.packCurrentA, isNull);
      expect(can.packCurrent.needsEstimateBadge, isFalse);
    });

    test('sinal parado além da idade máxima sai como não reportado', () {
      final can = LiveChargeCanState(entries: _schema());

      // Duas leituras com carimbos distintos fixam a última mudança...
      can.observe(_measuredCharge(tick: 1), 1000);
      can.observe(_measuredCharge(tick: 2), 2000);
      expect(can.packCurrent.hasValue, isTrue);

      // ...e daí o carimbo do daemon para de avançar: o barramento calou.
      can.observe(
        _measuredCharge(tick: 2),
        2000 + kBattSignalMaxAge.inMilliseconds + 1,
      );

      expect(
        can.packCurrent.validity,
        MeasurementValidity.unreported,
        reason: 'parar de publicar não é publicar um valor ruim',
      );
      expect(can.packCurrentA, isNull);
    });

    test('a potência do pacote herda a dúvida da corrente', () {
      final estimated = LiveChargeCanState(entries: _schema());
      estimated.observe(_measuredCharge(), 1000);

      final measured = LiveChargeCanState(
        entries: _schema(currentCalibrated: true),
      );
      measured.observe(
        _measuredCharge(currentValue: -2.1, currentCalibrated: true),
        1000,
      );

      // Mesmo número dos dois lados, confiança diferente. É por isso que a
      // potência não pode ser um double solto: V x I de uma estimativa é uma
      // estimativa, e nada no número diz isso.
      expect(estimated.packPowerKw, closeTo(measured.packPowerKw!, 0.001));
      expect(estimated.packPower.needsEstimateBadge, isTrue);
      expect(measured.packPower.isMeasured, isTrue);
    });

    test('a nota do zero assumido acompanha a estimativa', () {
      final can = LiveChargeCanState(entries: _schema());
      can.observe(_measuredCharge(), 1000);

      // Uma estimativa que o app não sabe explicar é uma que ele não devia
      // imprimir; o construtor exige a nota e ela sobrevive à derivação.
      expect(can.packCurrent.note, contains('$kBattCurrentAssumedZero'));
      expect(can.packPower.note, contains('$kBattCurrentAssumedZero'));
    });
  });
}
