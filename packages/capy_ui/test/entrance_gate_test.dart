import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:capy_ui/capy_ui.dart';

/// Stands in for a chart: counts how many times it has been *mounted*, which is
/// what actually decides whether an entrance animation runs.
class _Entrance extends StatefulWidget {
  const _Entrance({required this.onMount});

  final VoidCallback onMount;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const Text('chart');
}

/// Drives the gate from a test-controlled flag, so opening it goes through a
/// real rebuild rather than a fresh `pumpWidget`.
class _Host extends StatefulWidget {
  const _Host({required this.body, this.initiallyOpen = false});

  final Widget body;
  final bool initiallyOpen;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late bool _open = widget.initiallyOpen;
  int rebuilds = 0;

  @override
  Widget build(BuildContext context) {
    rebuilds++;
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TextButton(
              onPressed: () => setState(() => _open = true),
              child: const Text('open'),
            ),
            TextButton(
              // Rebuilds without changing `open` — nothing below should notice.
              onPressed: () => setState(() {}),
              child: const Text('touch'),
            ),
            Expanded(
              child: EntranceGate(open: _open, child: widget.body),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  group('EntranceGate', () {
    testWidgets('builds normally with no gate above', (tester) async {
      var mounts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => EntranceGate.guard(
              context,
              () => _Entrance(onMount: () => mounts++),
            ),
          ),
        ),
      );

      // The gallery, a test, and any screen that does not gate its entrances
      // all land here. An absent gate must never mean a closed one.
      expect(EntranceGate.isOpen(tester.element(find.text('chart'))), isTrue);
      expect(find.text('chart'), findsOneWidget);
      expect(mounts, 1);
    });

    testWidgets('a closed gate never builds the child', (tester) async {
      var built = 0;
      await tester.pumpWidget(
        _Host(
          body: Builder(
            builder: (context) => EntranceGate.guard(context, () {
              built++;
              return const Text('chart');
            }),
          ),
        ),
      );

      expect(find.text('chart'), findsNothing);
      // Not just hidden — the callback is the whole point: a closed gate must
      // not pay to describe what it is not going to show.
      expect(built, 0);
    });

    testWidgets('opening the gate mounts the child exactly once', (
      tester,
    ) async {
      var mounts = 0;
      await tester.pumpWidget(
        _Host(
          body: Builder(
            builder: (context) => EntranceGate.guard(
              context,
              () => _Entrance(onMount: () => mounts++),
            ),
          ),
        ),
      );
      expect(mounts, 0);

      await tester.tap(find.text('open'));
      await tester.pump();

      // The mount *is* the entrance — this is the frame the animation starts.
      expect(mounts, 1);
      expect(find.text('chart'), findsOneWidget);

      // Later rebuilds of the host must not remount it, or the entrance would
      // replay on every unrelated setState.
      await tester.tap(find.text('touch'));
      await tester.pump();
      expect(mounts, 1);
    });

    testWidgets('holds the default footprint open while closed', (
      tester,
    ) async {
      await tester.pumpWidget(
        _Host(
          body: Builder(
            builder: (context) =>
                EntranceGate.guard(context, () => const SizedBox.expand()),
          ),
        ),
      );

      // Whatever room the slot gave it, drawing nothing — so the surrounding
      // layout does not jump when the gate opens.
      final closed = tester.getSize(find.byType(EntranceGate));
      expect(closed.isEmpty, isFalse);
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(tester.getSize(find.byType(EntranceGate)), closed);
    });

    testWidgets('renders a caller-supplied placeholder instead', (
      tester,
    ) async {
      await tester.pumpWidget(
        _Host(
          body: Builder(
            builder: (context) => EntranceGate.guard(
              context,
              () => const Text('chart'),
              placeholder: const AspectRatio(aspectRatio: 1),
            ),
          ),
        ),
      );

      // The case the default gets wrong: content that sizes itself off its own
      // width rather than filling the slot.
      final box = tester.getSize(find.byType(AspectRatio));
      expect(box.width, box.height);
      expect(find.text('chart'), findsNothing);
    });

    testWidgets('does not notify dependents when open is unchanged', (
      tester,
    ) async {
      var builds = 0;
      await tester.pumpWidget(
        _Host(
          initiallyOpen: true,
          body: Builder(
            builder: (context) {
              builds++;
              return EntranceGate.guard(context, () => const Text('chart'));
            },
          ),
        ),
      );
      expect(builds, 1);

      await tester.tap(find.text('touch'));
      await tester.pump();

      // `Builder` here stands for a whole gated screen. Rebuilding it because
      // an ancestor rebuilt — with the gate reporting the same thing — is work
      // every gated subtree would pay for on every unrelated host setState.
      expect(builds, 1);
    });
  });
}
