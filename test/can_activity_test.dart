import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/can_activity.dart';
import 'package:capy_energy/core/can_bridge_models.dart';

RoadcastSchemaEntry _entry({
  required int index,
  required String name,
  required int canId,
  required String unit,
}) => RoadcastSchemaEntry(
  stableId: index,
  index: index,
  invalidSignalIndex: null,
  canId: canId,
  kind: 2,
  source: 1,
  width: 8,
  flags: 0x02,
  scale: 1,
  offset: 0,
  name: name,
  unit: unit,
);

final _entries = <RoadcastSchemaEntry>[
  _entry(index: 0, name: 'VCU_DrvPwrAct', canId: 0x315, unit: 'kW'),
  _entry(index: 1, name: 'BMSH_BattSOC', canId: 0x17A, unit: '%'),
  _entry(index: 2, name: 'SAS_SteerWheelAngle', canId: 0x0E0, unit: ''),
];

/// Monta uma leitura como a que a FFI devolve. `tsNs` é o que decide mudança:
/// é o instante da última alteração que o daemon publica por sinal.
CanBridgeReading _reading({
  required List<double> values,
  required List<int> tsNs,
  List<bool>? valid,
}) {
  return CanBridgeReading(
    values: Float32List.fromList(values),
    raws: Uint32List.fromList(values.map((v) => v.round()).toList()),
    timestampsNs: Int64List.fromList(tsNs),
    flags: Uint8List.fromList([
      for (var i = 0; i < values.length; i++)
        (valid == null || valid[i]) ? 0x01 : 0x00,
    ]),
  );
}

void main() {
  group('CanSignalActivity', () {
    test('first reading is a baseline, not a change', () {
      final tracker = CanActivityTracker(entries: _entries);

      tracker.observe(_reading(values: [1, 2, 3], tsNs: [100, 200, 300]), 1000);

      expect(tracker.changedCount, 0);
      expect(tracker.signals.every((s) => !s.everChanged), isTrue);
    });

    test('counts a change when the snapshot timestamp advances', () {
      final tracker = CanActivityTracker(entries: _entries);
      tracker.observe(_reading(values: [1, 2, 3], tsNs: [100, 200, 300]), 1000);

      tracker.observe(_reading(values: [9, 2, 3], tsNs: [400, 200, 300]), 1100);

      expect(tracker.signals[0].changeCount, 1);
      expect(tracker.signals[0].value, 9);
      expect(tracker.signals[1].changeCount, 0);
      expect(tracker.changedCount, 1);
    });

    // Este é o motivo de a detecção usar ts_ns e não comparação de valores: um
    // sinal que sai de A, vai a B e volta a A entre duas amostras mudou duas
    // vezes, e comparar valores diria que nada aconteceu.
    test(
      'detects a change even when the value returns to the previous one',
      () {
        final tracker = CanActivityTracker(entries: _entries);
        tracker.observe(_reading(values: [5, 0, 0], tsNs: [100, 0, 0]), 1000);

        tracker.observe(_reading(values: [5, 0, 0], tsNs: [500, 0, 0]), 1100);

        expect(tracker.signals[0].changeCount, 1);
      },
    );

    test('keeps history only on change, so the sparkline shows shape', () {
      final tracker = CanActivityTracker(entries: _entries);
      tracker.observe(_reading(values: [1, 0, 0], tsNs: [100, 0, 0]), 1000);
      tracker.observe(_reading(values: [1, 0, 0], tsNs: [100, 0, 0]), 1100);
      tracker.observe(_reading(values: [2, 0, 0], tsNs: [200, 0, 0]), 1200);

      expect(tracker.signals[0].history, [1, 2]);
    });

    test('rate counts only changes inside the rolling window', () {
      final tracker = CanActivityTracker(entries: _entries);
      tracker.observe(_reading(values: [0, 0, 0], tsNs: [1, 0, 0]), 0);
      tracker.observe(_reading(values: [1, 0, 0], tsNs: [2, 0, 0]), 1000);
      tracker.observe(_reading(values: [2, 0, 0], tsNs: [3, 0, 0]), 2000);

      expect(tracker.signals[0].changesPerSecond, 2 / 5);

      // Passa a janela inteira sem mudar: a taxa tem que zerar.
      tracker.observe(_reading(values: [2, 0, 0], tsNs: [3, 0, 0]), 20000);

      expect(tracker.signals[0].changesPerSecond, 0);
    });

    test('lean live mode keeps current state without auxiliary lists', () {
      final tracker = CanActivityTracker(
        entries: _entries,
        retainHistory: false,
        trackRate: false,
      );
      tracker.observe(_reading(values: [1, 0, 0], tsNs: [100, 0, 0]), 1000);
      tracker.observe(_reading(values: [2, 0, 0], tsNs: [200, 0, 0]), 1100);

      expect(tracker.signals[0].value, 2);
      expect(tracker.signals[0].changeCount, 1);
      expect(
        tracker.signals[0].ageSince(1200),
        const Duration(milliseconds: 100),
      );
      expect(tracker.signals[0].history, isEmpty);
      expect(tracker.signals[0].changesPerSecond, 0);
    });
  });

  group('CanActivityTracker ranking', () {
    CanActivityTracker seeded() {
      final tracker = CanActivityTracker(entries: _entries);
      tracker.observe(_reading(values: [0, 0, 0], tsNs: [1, 1, 1]), 0);
      // sinal 0 muda duas vezes, sinal 1 muda uma vez (mais recente), 2 nunca
      tracker.observe(_reading(values: [1, 0, 0], tsNs: [2, 1, 1]), 100);
      tracker.observe(_reading(values: [2, 0, 0], tsNs: [3, 1, 1]), 200);
      tracker.observe(_reading(values: [2, 5, 0], tsNs: [3, 2, 1]), 300);
      return tracker;
    }

    test('hides signals that never changed by default', () {
      final ranked = seeded().ranked();

      expect(ranked.map((s) => s.name), isNot(contains('SAS_SteerWheelAngle')));
      expect(ranked.length, 2);
    });

    test('recency puts the most recently changed first', () {
      final ranked = seeded().ranked();

      expect(ranked.first.name, 'BMSH_BattSOC');
    });

    test('rate puts the busiest first', () {
      final ranked = seeded().ranked(sort: CanActivitySort.rate);

      expect(ranked.first.name, 'VCU_DrvPwrAct');
    });

    test('search matches name or CAN id in hex', () {
      final tracker = seeded();

      expect(tracker.ranked(query: 'battsoc').single.name, 'BMSH_BattSOC');
      expect(tracker.ranked(query: '315').single.name, 'VCU_DrvPwrAct');
      expect(tracker.ranked(query: 'nada').isEmpty, isTrue);
    });

    test('onlyChanging false brings back the silent signals', () {
      final ranked = seeded().ranked(onlyChanging: false);

      expect(ranked.length, 3);
    });
  });

  group('CanActivityTracker muting', () {
    test('muted signals leave the list and come back on demand', () {
      final tracker = CanActivityTracker(entries: _entries);
      tracker.observe(_reading(values: [0, 0, 0], tsNs: [1, 1, 1]), 0);
      tracker.observe(_reading(values: [1, 2, 0], tsNs: [2, 2, 1]), 100);

      tracker.mute('VCU_DrvPwrAct');

      expect(tracker.ranked().map((s) => s.name), ['BMSH_BattSOC']);
      expect(tracker.ranked(showMuted: true).map((s) => s.name), [
        'VCU_DrvPwrAct',
      ]);
      expect(tracker.mutedCount, 1);

      tracker.unmute('VCU_DrvPwrAct');

      expect(tracker.ranked().length, 2);
    });

    // Silenciar existe para tirar ruído do caminho; um sinal silenciado nao pode
    // ser escolhido sozinho para o gauge.
    test('mostActive skips muted signals', () {
      final tracker = CanActivityTracker(entries: _entries);
      tracker.observe(_reading(values: [0, 0, 0], tsNs: [1, 1, 1]), 0);
      tracker.observe(_reading(values: [1, 0, 0], tsNs: [2, 1, 1]), 100);
      tracker.observe(_reading(values: [2, 0, 0], tsNs: [3, 1, 1]), 200);
      tracker.observe(_reading(values: [2, 9, 0], tsNs: [3, 2, 1]), 300);

      expect(tracker.mostActive()!.name, 'VCU_DrvPwrAct');

      tracker.mute('VCU_DrvPwrAct');

      expect(tracker.mostActive()!.name, 'BMSH_BattSOC');
    });

    test('validOnly drops signals whose source frame is absent', () {
      final tracker = CanActivityTracker(entries: _entries);
      tracker.observe(
        _reading(
          values: [0, 0, 0],
          tsNs: [1, 1, 1],
          valid: [true, false, true],
        ),
        0,
      );
      tracker.observe(
        _reading(
          values: [1, 2, 0],
          tsNs: [2, 2, 1],
          valid: [true, false, true],
        ),
        100,
      );

      expect(tracker.ranked(validOnly: true).map((s) => s.name), [
        'VCU_DrvPwrAct',
      ]);
    });
  });

  group('CanActivityTracker counters', () {
    test('activeCount only counts recent movement', () {
      final tracker = CanActivityTracker(entries: _entries);
      tracker.observe(_reading(values: [0, 0, 0], tsNs: [1, 1, 1]), 0);
      tracker.observe(_reading(values: [1, 0, 0], tsNs: [2, 1, 1]), 1000);

      expect(tracker.activeCount(1500), 1);
      expect(tracker.activeCount(9000), 0);
      expect(tracker.changedCount, 1);
    });

    test('resetAll clears history without losing the signal list', () {
      final tracker = CanActivityTracker(entries: _entries);
      tracker.observe(_reading(values: [0, 0, 0], tsNs: [1, 1, 1]), 0);
      tracker.observe(_reading(values: [1, 0, 0], tsNs: [2, 1, 1]), 100);

      tracker.resetAll();

      expect(tracker.changedCount, 0);
      expect(tracker.signals.length, 3);
      expect(tracker.signals[0].history, isEmpty);
    });
  });

  group('noise seeding', () {
    test('identifies counters and checksums as noise', () {
      expect(CanActivityTracker.isNoisy('SAS_Status_AliveCounter'), isTrue);
      expect(CanActivityTracker.isNoisy('ESC_Regen_Checksum'), isTrue);
      expect(CanActivityTracker.isNoisy('IPK_Second'), isTrue);
      expect(CanActivityTracker.isNoisy('VCU_DrvPwrAct'), isFalse);
    });

    test('lists only the noisy names present in the table', () {
      final tracker = CanActivityTracker(
        entries: [
          _entry(
            index: 0,
            name: 'SAS_Status_AliveCounter',
            canId: 0x0E0,
            unit: '',
          ),
          _entry(index: 1, name: 'VCU_DrvPwrAct', canId: 0x315, unit: 'kW'),
        ],
      );

      expect(tracker.noisySignalNames(), ['SAS_Status_AliveCounter']);
    });
  });
}
