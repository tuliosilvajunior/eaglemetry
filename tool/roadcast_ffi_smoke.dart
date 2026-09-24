import 'dart:io';

import 'package:capy_energy/core/roadcast_ffi.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.length > 2) {
    stderr.writeln(
      'usage: dart run tool/roadcast_ffi_smoke.dart '
      'SOCKET [CLIENT_LIBRARY]',
    );
    exitCode = 2;
    return;
  }

  final client = RoadcastFfi.attach(
    socketName: arguments.first,
    libraryName: arguments.length >= 2 ? arguments[1] : 'libroadcast_client.so',
  );
  if (client == null) {
    stderr.writeln(
      'Roadcast connection failed: ${RoadcastFfi.lastAttachError}',
    );
    exitCode = 1;
    return;
  }
  try {
    final schema = client.schema();
    final indices = [for (final entry in schema) entry.index];
    if (indices.toSet().length != indices.length) {
      stderr.writeln(
        'Roadcast stable identities resolved to duplicate indexes',
      );
      exitCode = 1;
      return;
    }
    final drivePower = schema
        .where((entry) => entry.name == 'VCU_DrvPwrAct')
        .toList(growable: false);
    if (drivePower.length != 1 ||
        drivePower.single.canId != 0x315 ||
        drivePower.single.unit != 'kW' ||
        !drivePower.single.isCalibrated) {
      stderr.writeln(
        'Roadcast schema has no unique calibrated VCU_DrvPwrAct '
        'on CAN 0x315 in kW',
      );
      exitCode = 1;
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    final reading = client.read(indices);
    if (!client.isAlive() || reading.length != schema.length) {
      stderr.writeln('Roadcast cache is unavailable');
      exitCode = 1;
      return;
    }
    var valid = 0;
    for (var index = 0; index < reading.length; index++) {
      if (reading.isValidAt(index)) valid++;
    }
    stdout.writeln(
      'roadcast-ffi: signals=${client.signalCount} '
      'frames=${client.frameCount} hz=${client.hz} '
      'resolved=${indices.length} valid=$valid '
      'ageNs=${client.sampleAgeNanos()}',
    );
  } finally {
    client.detach();
  }
}
