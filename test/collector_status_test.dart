import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_api.dart';

void main() {
  test('preserves native persistence health metadata', () {
    final status = CollectorStatus.fromMap({
      'running': true,
      'collectorStatus': 'running',
      'persistence': {
        'frames': {
          'writer': {'queueDepth': 3, 'failedWrites': 1},
        },
        'database': {'journalMode': 'wal', 'walBytes': 4096},
      },
    });

    final frames = status.persistence['frames']! as Map<Object?, Object?>;
    final writer = frames['writer']! as Map<Object?, Object?>;
    final database = status.persistence['database']! as Map<Object?, Object?>;
    expect(writer['queueDepth'], 3);
    expect(writer['failedWrites'], 1);
    expect(database['journalMode'], 'wal');
    expect(database['walBytes'], 4096);
  });

  test('defaults persistence health for older native payloads', () {
    final status = CollectorStatus.fromMap(const {});
    expect(status.persistence, isEmpty);
  });
}
