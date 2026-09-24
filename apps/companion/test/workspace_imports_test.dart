import 'package:capy_ui/capy_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  test('shared packages resolve in this target', () {
    expect(capyUiPackage, 'capy_ui');
    expect(EfficiencyUnit.values, isNotEmpty);
  });
}
