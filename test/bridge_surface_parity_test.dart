import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the two halves of the telemetry method channel against each other.
///
/// `TelemetryBridge.kt` writes the handler names and `TelemetryApi` writes the
/// call names, and until now nothing compared the two lists. A rename on one
/// side compiled, passed both suites, and reached the car as a missing value.
/// The gap was not theoretical: `setHvacTemperature` and `setHvacFanSpeed`
/// shipped as handlers with no caller for as long as they existed, and three
/// documents listed them as live.
///
/// This test is scaffolding for the Pigeon migration. When the generated
/// interface owns the surface, the compiler makes the same assertion and this
/// file should be deleted rather than maintained.
void main() {
  const bridgePath =
      'android/app/src/main/kotlin/com/timhss/capyenergy/bridge/'
      'TelemetryBridge.kt';
  const apiPath = 'lib/core/telemetry_api.dart';
  const mockPath = 'lib/core/mock_telemetry_source.dart';
  const pigeonPath = 'pigeons/telemetry_wire.dart';

  /// Methods the mock answers with a computed DTO instead of a map.
  ///
  /// Empty since slice 5: the session reads are the store's three questions,
  /// and every store — Room, Sqflite, the mock — answers them itself. Nothing
  /// is derived behind the untyped surface any more. A method added here again
  /// has to be added deliberately.
  const derived = <String>{};

  late Set<String> kotlinHandlers;
  late Set<String> dartCalls;
  late Set<String> mockCases;
  late Set<String> pigeonMethods;

  setUpAll(() {
    kotlinHandlers = _kotlinHandlerNames(File(bridgePath).readAsStringSync());
    dartCalls = _dartMethodNames(File(apiPath).readAsStringSync());
    mockCases = _mockCaseNames(File(mockPath).readAsStringSync());
    pigeonMethods = _pigeonMethodNames(File(pigeonPath).readAsStringSync());
  });

  test('the extractors find the surface they are meant to read', () {
    // Guards the regexes themselves: a syntax change that made either pattern
    // match nothing would otherwise turn this whole file into a silent pass.
    expect(
      kotlinHandlers.length,
      greaterThanOrEqualTo(35),
      reason: 'the Kotlin handler pattern stopped matching $bridgePath',
    );
    expect(
      dartCalls.length,
      greaterThanOrEqualTo(35),
      reason: 'the Dart invocation pattern stopped matching $apiPath',
    );
    expect(
      mockCases.length,
      greaterThanOrEqualTo(35),
      reason: 'the mock case pattern stopped matching $mockPath',
    );
    expect(
      pigeonMethods,
      isNotEmpty,
      reason: 'the pigeon method pattern stopped matching $pigeonPath',
    );
    expect(kotlinHandlers, contains('getTelemetrySnapshot'));
    expect(dartCalls, contains('getTelemetrySnapshot'));
    expect(mockCases, contains('getTelemetrySnapshot'));
  });

  test('a pigeon method left the shared channel on both sides', () {
    // A method described in the schema gets its own generated channel. Leaving
    // it in the `when` or in `_invoke` would keep a second, untyped route to
    // the same call alive, and only one of the two would then be maintained.
    expect(
      pigeonMethods.intersection(kotlinHandlers),
      isEmpty,
      reason: 'still dispatched by name in $bridgePath',
    );
    expect(
      pigeonMethods.intersection(dartCalls),
      isEmpty,
      reason: 'still invoked by name in $apiPath',
    );
  });

  test('every native handler has a caller in TelemetryApi', () {
    expect(
      kotlinHandlers.difference(dartCalls),
      isEmpty,
      reason:
          'These methods are handled in $bridgePath and never invoked from '
          '$apiPath. Either add the Dart wrapper or delete the handler; do '
          'not leave the surface asymmetric.',
    );
  });

  test('every TelemetryApi call has a mock answer', () {
    // The mock only runs on web and under CAPY_MOCK_TELEMETRY, so a method
    // added with no case there compiles, passes on the car, and throws in the
    // one build nobody runs before merging.
    expect(
      dartCalls.difference(mockCases),
      derived,
      reason:
          'These methods are invoked from $apiPath with no case in $mockPath '
          'and no derive method behind them. On the web build they throw.',
    );
  });

  /// TelemetryStore methods answered by MockTelemetryStore rather than MockTelemetrySource.
  const storePigeonMethods = {
    'storeListSessions',
    'storeGetSession',
    'storeGetSeries',
  };

  test('the mock answers nothing the api never asks for', () {
    // A pigeon method still needs a mock case: the mock has no typed channel,
    // so it answers the generated call from the same map it always built.
    expect(
      mockCases.difference(dartCalls),
      pigeonMethods.difference(storePigeonMethods),
      reason:
          'These cases in $mockPath answer methods nothing calls. A mock for '
          'a method that no longer exists is data kept alive by nothing.',
    );
  });

  test('every TelemetryApi call has a native handler', () {
    expect(
      dartCalls.difference(kotlinHandlers),
      isEmpty,
      reason:
          'These methods are invoked from $apiPath with no handler in '
          '$bridgePath. On the car they fail as MissingPluginException.',
    );
  });
}

/// Handler names from the `when (call.method)` arms.
///
/// Matches `"name" ->` at the start of a line, which is the only shape the
/// dispatch uses. The other `when` in the file switches on an enum, so it
/// cannot collide.
Set<String> _kotlinHandlerNames(String source) => RegExp(
  r'''^\s*"([A-Za-z][A-Za-z0-9]*)"\s*->''',
  multiLine: true,
).allMatches(source).map((match) => match.group(1)!).toSet();

/// Method names passed to `_invoke`, or straight to the source.
///
/// `\s*` spans newlines, so it reads both the one-line and the wrapped call
/// shapes that the file mixes. `_source.call` and `_source.callOrNull` are the
/// two methods that bypass `_invoke`, for the replies that may be null.
/// Method names declared on the `@HostApi()` class in the pigeon schema.
///
/// Matches the return type and name of an abstract method, which is the only
/// declaration shape the schema uses.
Set<String> _pigeonMethodNames(String source) {
  final api = RegExp(
    r'@HostApi\(\)\s*abstract class \w+ \{(.*?)\n\}',
    dotAll: true,
  ).firstMatch(source);
  if (api == null) return const {};
  return RegExp(
    r'^\s{2}[\w<>?]+\s+(\w+)\s*\(',
    multiLine: true,
  ).allMatches(api.group(1)!).map((match) => match.group(1)!).toSet();
}

/// Method names from the mock's `'name' =>` switch arms.
Set<String> _mockCaseNames(String source) => RegExp(
  r"""^\s*'([A-Za-z][A-Za-z0-9]*)'\s*=>""",
  multiLine: true,
).allMatches(source).map((match) => match.group(1)!).toSet();

Set<String> _dartMethodNames(String source) => RegExp(
  r'''(?:_invoke|_source\.callOrNull|_source\.call)\s*\(\s*['"]([A-Za-z][A-Za-z0-9]*)['"]''',
).allMatches(source).map((match) => match.group(1)!).toSet();
