import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/telemetry_api.dart';
import 'package:capy_energy/core/telemetry_scope.dart';

/// Reads the api the way a screen does: once, from `initState`.
class _Probe extends StatefulWidget {
  const _Probe({required this.onRead});

  final void Function(TelemetryApi api) onRead;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  late final TelemetryApi _api = TelemetryScope.of(context);

  @override
  void initState() {
    super.initState();
    // Screens hold the api in a field read here. A scope that could only be
    // reached later would not fit the surfaces it exists for.
    widget.onRead(_api);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  testWidgets('a screen under the scope gets the scope api', (tester) async {
    final scoped = TelemetryApi();
    TelemetryApi? seen;

    await tester.pumpWidget(
      TelemetryScope(
        api: scoped,
        child: _Probe(onRead: (api) => seen = api),
      ),
    );

    expect(identical(seen, scoped), isTrue);
    expect(identical(seen, TelemetryApi.shared), isFalse);
  });

  testWidgets('a screen with no scope above it gets the shared api', (
    tester,
  ) async {
    TelemetryApi? seen;

    // Every widget test pumps its screen without a root, and the app itself
    // installs the scope. The fallback is what makes those two the same api.
    await tester.pumpWidget(_Probe(onRead: (api) => seen = api));

    expect(identical(seen, TelemetryApi.shared), isTrue);
  });

  testWidgets('the shared api is one object for the process', (tester) async {
    expect(identical(TelemetryApi.shared, TelemetryApi.shared), isTrue);
  });

  testWidgets('the nearest scope wins, so a subtree can be redirected', (
    tester,
  ) async {
    final outer = TelemetryApi();
    final inner = TelemetryApi();
    TelemetryApi? seen;

    await tester.pumpWidget(
      TelemetryScope(
        api: outer,
        child: TelemetryScope(
          api: inner,
          child: _Probe(onRead: (api) => seen = api),
        ),
      ),
    );

    expect(identical(seen, inner), isTrue);
  });
}
