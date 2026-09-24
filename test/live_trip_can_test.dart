import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/can_bridge_models.dart';
import 'package:capy_energy/core/live_trip_can.dart';
import 'package:telemetry_core/telemetry_core.dart';

RoadcastSchemaEntry _entry(int index, String name) => RoadcastSchemaEntry(
  stableId: index,
  index: index,
  invalidSignalIndex: null,
  canId: 0x100 + index,
  kind: 2,
  source: 1,
  width: 8,
  flags: 0x02,
  scale: 1,
  offset: 0,
  name: name,
  unit: '',
);

/// Entradas na ordem do watchlist, que é a ordem em que a leitura em lote volta.
final _entries = <RoadcastSchemaEntry>[
  for (var i = 0; i < LiveTripCanNames.watchlist.length; i++)
    _entry(i, LiveTripCanNames.watchlist[i]),
];

int _positionOf(String name) => LiveTripCanNames.watchlist.indexOf(name);

/// Monta a leitura que a FFI devolveria. `values` e `raws` são por nome para o teste
/// não depender da ordem literal do watchlist.
CanBridgeReading _reading({
  Map<String, double> values = const {},
  Map<String, int> raws = const {},
  Set<String> invalid = const {},
  Set<String> calibrated = const {},
  int tsNs = 1000,
}) {
  final count = LiveTripCanNames.watchlist.length;
  final flags = Uint8List(count);
  final valueList = Float32List(count);
  final rawList = Uint32List(count);
  for (var i = 0; i < count; i++) {
    final name = LiveTripCanNames.watchlist[i];
    valueList[i] = values[name] ?? (raws[name] ?? 0).toDouble();
    rawList[i] = raws[name] ?? (values[name] ?? 0).round();
    flags[i] =
        (invalid.contains(name) ? 0x00 : 0x01) |
        (calibrated.contains(name) ? 0x02 : 0x00);
  }
  return CanBridgeReading(
    values: valueList,
    raws: rawList,
    timestampsNs: Int64List(count)..fillRange(0, count, tsNs),
    flags: flags,
  );
}

void main() {
  test('SOC e tensão só saem calibrados', () {
    final state = LiveTripCanState(entries: _entries);

    state.observe(
      _reading(
        values: {LiveTripCanNames.soc: 63.4, LiveTripCanNames.packVolts: 386.2},
      ),
      1000,
    );
    expect(
      state.socPercent,
      isNull,
      reason: 'sem o bit de calibração o valor é cru vezes um palpite',
    );
    expect(state.packVoltage, isNull);

    state.observe(
      _reading(
        values: {LiveTripCanNames.soc: 63.4, LiveTripCanNames.packVolts: 386.2},
        calibrated: {LiveTripCanNames.soc, LiveTripCanNames.packVolts},
        tsNs: 2000,
      ),
      1100,
    );
    expect(state.socPercent, closeTo(63.4, 0.01));
    expect(state.packVoltage, closeTo(386.2, 0.01));
  });

  test('potência de tração exige a calibração publicada pelo Roadcast', () {
    final state = LiveTripCanState(entries: _entries);
    state.observe(_reading(values: {LiveTripCanNames.drivePower: -12.5}), 1000);
    expect(state.drivePowerKw, isNull);

    state.observe(
      _reading(
        values: {LiveTripCanNames.drivePower: -12.5},
        calibrated: {LiveTripCanNames.drivePower},
        tsNs: 2000,
      ),
      1100,
    );
    expect(state.drivePowerKw, closeTo(-12.5, 0.01));
  });

  test('inclinação usa diretamente a calibração Roadcast em porcento', () {
    expect(LiveTripCanNames.roadIncline, 'ESC_RoadInclnRoadIncln');
    final state = LiveTripCanState(entries: _entries);

    state.observe(_reading(values: {LiveTripCanNames.roadIncline: -0.2}), 1000);
    expect(
      state.roadInclinePercent,
      isNull,
      reason: 'a dash não deve interpretar a contagem crua como inclinação',
    );

    state.observe(
      _reading(
        values: {LiveTripCanNames.roadIncline: -0.2},
        calibrated: {LiveTripCanNames.roadIncline},
        tsNs: 2000,
      ),
      1100,
    );
    expect(state.roadInclinePercent, closeTo(-0.2, 0.001));
  });

  test(
    'o ângulo da inclinação é a arco-tangente do porcento, não o porcento',
    () {
      final state = LiveTripCanState(entries: _entries);

      expect(state.roadInclineDegrees, isNull);

      state.observe(
        _reading(
          values: {LiveTripCanNames.roadIncline: 22.6},
          calibrated: {LiveTripCanNames.roadIncline},
        ),
        1000,
      );

      // 22,6 % é o extremo que este barramento alcança. Tratá-lo como grau erraria
      // por quase 5°, que é a razão de a conversão existir.
      expect(state.roadInclineDegrees, closeTo(12.73, 0.01));

      state.observe(
        _reading(
          values: {LiveTripCanNames.roadIncline: -0.8},
          calibrated: {LiveTripCanNames.roadIncline},
          tsNs: 2000,
        ),
        1100,
      );

      // A leitura medida no carro parado em 2026-08-10.
      expect(state.roadInclineDegrees, closeTo(-0.458, 0.001));
    },
  );

  test('sem calibração publicada não há ângulo, nem pelo cru', () {
    final state = LiveTripCanState(entries: _entries);

    state.observe(_reading(values: {LiveTripCanNames.roadIncline: 1010}), 1000);

    expect(state.roadInclineDegrees, isNull);
  });

  test('velocidade vem de ESC_VehicleSpeed e honra o bit Invalid', () {
    expect(LiveTripCanNames.speed, 'ESC_VehicleSpeed');
    expect(LiveTripCanNames.speedInvalid, 'ESC_VehicleSpeedInvalid');
    expect(LiveTripCanNames.watchlist, isNot(contains('SEC_VehicleSpeed')));

    final state = LiveTripCanState(entries: _entries);
    state.observe(
      _reading(
        values: {LiveTripCanNames.speed: 42.5},
        calibrated: {LiveTripCanNames.speed},
      ),
      1000,
    );

    expect(state.speedKmh, closeTo(42.5, 0.01));

    state.observe(
      _reading(
        values: {LiveTripCanNames.speed: 42.5},
        raws: {LiveTripCanNames.speedInvalid: 1},
        calibrated: {LiveTripCanNames.speed},
        tsNs: 2000,
      ),
      1100,
    );

    expect(state.speedKmh, isNull);
    expect(state.speedRaw, isNull);
  });

  test('BattCurr usa calibração Roadcast ou estimativa documentada', () {
    final state = LiveTripCanState(entries: _entries);

    state.observe(_reading(raws: {LiveTripCanNames.packCurrent: 4979}), 1000);
    expect(state.packCurrentA, closeTo(-2.1, 0.01));
    expect(state.packCurrent.needsEstimateBadge, isTrue);

    state.observe(
      _reading(
        values: {LiveTripCanNames.packCurrent: -2.4},
        raws: {LiveTripCanNames.packCurrent: 4976},
        calibrated: {LiveTripCanNames.packCurrent},
        tsNs: 2000,
      ),
      1100,
    );
    expect(state.packCurrentA, closeTo(-2.4, 0.01));
    expect(state.packCurrent.isMeasured, isTrue);
  });

  test('sinal inválido pelo companheiro Invalid vira leitura ausente', () {
    final state = LiveTripCanState(entries: _entries);

    state.observe(
      _reading(
        raws: {LiveTripCanNames.pedal: 137, LiveTripCanNames.pedalInvalid: 1},
      ),
      1000,
    );
    expect(state.pedalRaw, isNull);
    expect(state.pedalFraction, isNull);

    state.observe(
      _reading(
        raws: {LiveTripCanNames.pedal: 137, LiveTripCanNames.pedalInvalid: 0},
        tsNs: 2000,
      ),
      1100,
    );
    expect(state.pedalRaw, 137);
    expect(state.pedalFraction, closeTo(137 / 255, 0.001));
  });

  test('bit do freio é lido como estado, não como número', () {
    final state = LiveTripCanState(entries: _entries);

    state.observe(_reading(raws: {LiveTripCanNames.brake: 1}), 1000);
    expect(state.brakePressed, isTrue);

    state.observe(
      _reading(raws: {LiveTripCanNames.brake: 0}, tsNs: 2000),
      1100,
    );
    expect(state.brakePressed, isFalse);

    state.observe(
      _reading(
        raws: {LiveTripCanNames.brake: 1},
        invalid: {LiveTripCanNames.brakeInvalid},
        tsNs: 3000,
      ),
      1200,
    );
    expect(
      state.brakePressed,
      isNull,
      reason: 'sem poder ler o bit de validade não se afirma nada',
    );
  });

  test('nome ausente do schema não derruba as demais leituras', () {
    final partial = <RoadcastSchemaEntry>[
      for (final entry in _entries)
        if (entry.name != LiveTripCanNames.regenLevel) entry,
    ];
    final state = LiveTripCanState(entries: partial);

    state.observe(
      CanBridgeReading(
        values: Float32List(partial.length),
        raws: Uint32List(partial.length),
        timestampsNs: Int64List(partial.length),
        flags: Uint8List(partial.length)..fillRange(0, partial.length, 0x01),
      ),
      1000,
    );

    expect(state.regenLevel, isNull);
    expect(state.signal(LiveTripCanNames.regenLevel), isNull);
    expect(state.pedalRaw, 0);
  });

  test('histórico do sinal alimenta a sparkline só quando o valor muda', () {
    final state = LiveTripCanState(entries: _entries);
    final power = LiveTripCanNames.drivePower;

    state.observe(_reading(values: {power: 10}, tsNs: 1000), 1000);
    state.observe(_reading(values: {power: 10}, tsNs: 1000), 1100);
    expect(state.historyOf(power), [10]);

    state.observe(_reading(values: {power: 12}, tsNs: 2000), 1200);
    expect(state.historyOf(power), [10, 12]);
  });

  test('Eco Coach deriva movimento do VEHICLE_SPEED, não do candidato CAN', () {
    final state = LiveTripCanState(entries: _entries);
    final calibrated = {LiveTripCanNames.speed, LiveTripCanNames.drivePower};
    state.observe(
      _reading(
        values: {LiveTripCanNames.speed: 20},
        calibrated: calibrated,
        tsNs: 1000000000,
      ),
      1000,
    );
    expect(state.ecoCoach.score, isNull);

    state.observeVehicleSpeed(
      speedKmh: 20,
      nowMs: 1000,
      motionTimestampNanos: 1000000000,
    );
    state.observe(
      _reading(
        values: {LiveTripCanNames.speed: 99, LiveTripCanNames.drivePower: 45},
        raws: {LiveTripCanNames.pedal: 180},
        calibrated: calibrated,
        tsNs: 2000000000,
      ),
      2000,
    );
    state.observeVehicleSpeed(
      speedKmh: 30,
      nowMs: 2000,
      motionTimestampNanos: 2000000000,
    );

    expect(state.ecoCoach.score, isNotNull);
    expect(state.ecoCoach.accelerationMps2, greaterThan(1));
    final score = state.ecoCoach.score;

    state.observe(
      _reading(
        values: {LiveTripCanNames.speed: 120, LiveTripCanNames.drivePower: 45},
        raws: {LiveTripCanNames.pedal: 180},
        calibrated: calibrated,
        tsNs: 3000000000,
      ),
      2016,
    );
    expect(state.ecoCoach.score, score);

    state.observeVehicleSpeed(
      speedKmh: null,
      nowMs: 5001,
      motionTimestampNanos: 2000000000,
    );
    expect(state.ecoCoach.score, isNull);
    state.observe(
      _reading(
        values: {LiveTripCanNames.drivePower: 60},
        calibrated: {LiveTripCanNames.drivePower},
        tsNs: 4000000000,
      ),
      5100,
    );
    expect(
      state.ecoCoach.score,
      isNull,
      reason: 'demanda Roadcast não reutiliza velocidade VHAL obsoleta',
    );
  });

  test('expõe candidatos OEM como crus, sem fingir calibração', () {
    final state = LiveTripCanState(entries: _entries);
    state.observe(
      _reading(
        raws: {
          LiveTripCanNames.averageConsumption: 916,
          LiveTripCanNames.averageConsumption1: 337,
          LiveTripCanNames.totalOdometer: 17051,
        },
      ),
      1000,
    );

    expect(state.averageConsumptionRaw, 916);
    expect(state.averageConsumption1Raw, 337);
    expect(state.totalOdometerRaw, 17051);
    expect(state.estimatedTotalOdometerKm, 17051);
  });

  group('ImpliedScale', () {
    test('devolve a mediana das razões observadas', () {
      final probe = ImpliedScale();
      probe.observe(raw: 1000, reference: 56.0);
      probe.observe(raw: 1000, reference: 57.0);
      probe.observe(raw: 1000, reference: 56.5);

      expect(probe.sampleCount, 3);
      expect(probe.scale, closeTo(0.0565, 0.0001));
    });

    test('descarta amostras onde a quantização domina', () {
      final probe = ImpliedScale();
      probe.observe(raw: 2, reference: 30.0);
      probe.observe(raw: 1000, reference: 2.0);

      expect(probe.sampleCount, 0);
      expect(probe.scale, isNull);
    });

    test('mediana resiste a um par dessincronizado', () {
      final probe = ImpliedScale();
      for (var i = 0; i < 10; i++) {
        probe.observe(raw: 1000, reference: 56.0);
      }
      // Aceleração forte: o cru já subiu e a property ainda não.
      probe.observe(raw: 1000, reference: 90.0);

      expect(probe.scale, closeTo(0.056, 0.001));
    });

    test('janela limita quantas razões entram na conta', () {
      final probe = ImpliedScale(window: 4);
      for (var i = 0; i < 20; i++) {
        probe.observe(raw: 1000, reference: 56.0);
      }
      expect(probe.sampleCount, 4);
    });
  });

  test('watchlist é única e traz o companheiro Invalid de cada gate', () {
    expect(
      LiveTripCanNames.watchlist.toSet().length,
      LiveTripCanNames.watchlist.length,
    );
    for (final name in [
      LiveTripCanNames.pedalInvalid,
      LiveTripCanNames.brakeInvalid,
    ]) {
      expect(_positionOf(name), greaterThanOrEqualTo(0), reason: name);
    }
  });

  group('o motivo de um valor não valer', () {
    test('o bit Invalid levantado sai como inválido, não como ausente', () {
      final state = LiveTripCanState(entries: _entries);

      state.observe(
        _reading(
          values: {LiveTripCanNames.speed: 62.0},
          raws: {LiveTripCanNames.speedInvalid: 1},
          calibrated: {LiveTripCanNames.speed},
        ),
        1000,
      );

      // O ECU publicou a velocidade e disse para não confiar nela. Isso não é o
      // mesmo que o sinal não existir, e o app precisa poder separar os dois
      // para saber onde procurar o defeito.
      expect(state.speed.validity, MeasurementValidity.invalid);
      expect(state.speed.note, contains(LiveTripCanNames.speedInvalid));
      expect(state.speedKmh, isNull);
    });

    test('o bit Invalid ausente do barramento sai como não reportado', () {
      final state = LiveTripCanState(entries: _entries);

      state.observe(
        _reading(
          values: {LiveTripCanNames.speed: 62.0},
          calibrated: {LiveTripCanNames.speed},
          invalid: {LiveTripCanNames.speedInvalid},
        ),
        1000,
      );

      // Sem ler o bit não dá para afirmar que o valor presta. Tratar a ausência
      // como "válido" é o otimismo que some junto com a falha.
      expect(state.speed.validity, MeasurementValidity.unreported);
      expect(state.speedKmh, isNull);
    });

    test('com o bit baixo e escala publicada é medição', () {
      final state = LiveTripCanState(entries: _entries);

      state.observe(
        _reading(
          values: {LiveTripCanNames.speed: 62.0},
          raws: {LiveTripCanNames.speedInvalid: 0},
          calibrated: {LiveTripCanNames.speed},
        ),
        1000,
      );

      expect(state.speed.isMeasured, isTrue);
      expect(state.speedKmh, closeTo(62.0, 0.001));
    });

    test('sem escala publicada e sem hipótese documentada não há número', () {
      final state = LiveTripCanState(entries: _entries);

      state.observe(
        _reading(
          values: {LiveTripCanNames.speed: 62.0},
          raws: {LiveTripCanNames.speedInvalid: 0},
        ),
        1000,
      );

      // Cru vezes um palpite não é uma medida, e também não é uma estimativa:
      // uma estimativa exige a hipótese escrita, que este sinal não tem.
      expect(state.speed.validity, MeasurementValidity.unreported);
      expect(state.speed.needsEstimateBadge, isFalse);
    });
  });
}
