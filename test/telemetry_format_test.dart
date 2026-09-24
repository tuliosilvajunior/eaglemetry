import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_format.dart';

void main() {
  test('delta SOC mostra perda e ganho com sinal explícito', () {
    expect(socDeltaLabel(71.0, 70.9), '-0.1%');
    expect(socDeltaLabel(70.9, 71.0), '+0.1%');
  });

  test('duração canônica nativa não depende do relógio civil', () {
    final duration = durationFromMillis(184654);

    expect(formatDuration(duration), '03:04');
    expect(durationFromMillis(-1), isNull);
  });

  test('fallback civil recusa duração implausível', () {
    final start = DateTime.utc(2025, 5, 23);
    final end = DateTime.utc(2026, 7, 31);

    expect(
      boundedDurationBetween(start, end, maximum: const Duration(hours: 48)),
      isNull,
    );
  });
}
