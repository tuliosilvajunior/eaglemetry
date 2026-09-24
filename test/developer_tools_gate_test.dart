import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/developer_tools_gate.dart';

void main() {
  test('developer tools unlock after eight easter egg taps in memory', () {
    final gate = DeveloperToolsGate.instance..reset();

    for (var i = 0; i < DeveloperToolsGate.unlockTapCount - 1; i++) {
      gate.registerEasterEggTap();
    }

    expect(gate.unlocked, isFalse);

    gate.registerEasterEggTap();

    expect(gate.unlocked, isTrue);

    gate.reset();
  });
}
