import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_api.dart';

void main() {
  test('parses an available app update', () {
    final status = AppUpdateStatus.fromMap(const {
      'checked': true,
      'updateAvailable': true,
      'compatible': true,
      'installedVersionName': '0.4.3',
      'installedVersionCode': 45,
      'availableVersionName': '0.4.6',
      'availableVersionCode': 59,
      'requiresReflash': false,
      'installScheduled': false,
      'changelog': [
        {
          'versionName': '0.4.6',
          'versionCode': 59,
          'notes': {
            'en': ['English note'],
            'pt': ['Nota em português'],
            'ru': ['Примечание'],
          },
        },
      ],
    });

    expect(status.checked, isTrue);
    expect(status.updateAvailable, isTrue);
    expect(status.installedVersionCode, 45);
    expect(status.availableVersionName, '0.4.6');
    expect(status.availableVersionCode, 59);
    expect(status.requiresReflash, isFalse);
    expect(status.changelog.single.notesForLanguage('pt'), [
      'Nota em português',
    ]);
    expect(status.changelog.single.notesForLanguage('de'), ['English note']);
  });

  test('accepts update status from clients without a changelog', () {
    final status = AppUpdateStatus.fromMap(const {
      'installedVersionName': '0.8.0',
      'installedVersionCode': 99,
    });

    expect(status.changelog, isEmpty);
  });
}
