import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_api.dart';

void main() {
  test('parses an available compatible Roadcast update', () {
    final status = RoadcastUpdateStatus.fromMap({
      'checked': true,
      'channel': 'edge',
      'updateAvailable': true,
      'compatible': true,
      'installedSha256': 'old',
      'installedVersion': null,
      'installedCommit': null,
      'availableVersion': 'edge',
      'availableCommit': '981dbacc437ef16593c5fafa22f92d76371980ad',
      'availableSha256':
          'e6d6fb610bf4146f3156716f9d1f5d348a539f1ba70627bdff2087dfef156f18',
      'error': null,
    });

    expect(status.checked, isTrue);
    expect(status.channel, 'edge');
    expect(status.updateAvailable, isTrue);
    expect(status.compatible, isTrue);
    expect(status.installedSha256, 'old');
    expect(status.availableVersion, 'edge');
    expect(status.availableCommit, startsWith('981dbacc'));
  });

  test('preserves an incompatibility explanation', () {
    final status = RoadcastUpdateStatus.fromMap({
      'checked': true,
      'channel': 'edge',
      'updateAvailable': false,
      'compatible': false,
      'error': 'client protocol 3 is not supported',
    });

    expect(status.updateAvailable, isFalse);
    expect(status.compatible, isFalse);
    expect(status.error, contains('protocol 3'));
  });
}
