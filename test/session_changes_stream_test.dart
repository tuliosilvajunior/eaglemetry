import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/channel_telemetry_source.dart';
import 'package:capy_energy/core/mock_telemetry_source.dart';
import 'package:capy_energy/core/telemetry_api.dart';

/// Who may listen for a session write, and how many at once.
///
/// The v2 shell keeps every tab mounted, so the charging screen and the energy
/// monitor are both subscribed for the whole run of the app. Two subscribers is
/// the normal case here, not a corner.
void main() {
  group('sessionChanges', () {
    test('every subscriber gets the same stream, so one channel exists', () {
      const source = ChannelTelemetrySource();

      // The generated `sessionsChanged()` builds a fresh EventChannel on each
      // call, and a second channel of the same name replaces the first one's
      // handler on the messenger. Two screens would then silence each other,
      // and the failure looks exactly like a car that is not writing sessions.
      expect(identical(source.sessionChanges(), source.sessionChanges()), true);
    });

    test('the mock answers more than one listener', () async {
      final source = MockTelemetrySource();

      final first = source.sessionChanges().toList();
      final second = source.sessionChanges().toList();

      // The mock writes nothing, so both close empty. Listening twice must not
      // throw: a single-subscription stream here would fail the second screen
      // to open rather than the first.
      expect(await first, isEmpty);
      expect(await second, isEmpty);
    });

    test('the api hands its source stream through unchanged', () {
      final api = TelemetryApi(source: const ChannelTelemetrySource());

      expect(identical(api.sessionChanges(), api.sessionChanges()), true);
    });
  });
}
