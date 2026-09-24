import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

/// A read the test finishes by hand, so an overlap can be built on purpose.
class _ManualRead {
  final List<Completer<void>> pending = <Completer<void>>[];
  int started = 0;

  Future<void> call() {
    started++;
    final completer = Completer<void>();
    pending.add(completer);
    return completer.future;
  }

  void finishAll() {
    for (final completer in pending) {
      if (!completer.isCompleted) completer.complete();
    }
    pending.clear();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('one read at a time', () {
    test('a tick during a read is dropped, not queued', () {
      fakeAsync((async) {
        final read = _ManualRead();
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: read.call,
        );

        loop.start();
        async.flushMicrotasks();
        expect(read.started, 1);

        // Three ticks pass while the first read is still out. Queueing them
        // would send three more reads of a question already asked.
        async.elapse(const Duration(seconds: 16));
        expect(read.started, 1);
        expect(loop.isReading, isTrue);

        read.finishAll();
        async.flushMicrotasks();
        expect(loop.isReading, isFalse);

        // The next tick reads with fresher data than any dropped tick had.
        async.elapse(const Duration(seconds: 5));
        expect(read.started, 2);

        read.finishAll();
        loop.dispose();
        async.flushMicrotasks();
      });
    });

    test('two reads never overlap, so the newer answer always lands last', () {
      fakeAsync((async) {
        final completions = <int>[];
        var index = 0;
        var inFlight = 0;
        var peakInFlight = 0;
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: () async {
            final id = ++index;
            inFlight++;
            peakInFlight = inFlight > peakInFlight ? inFlight : peakInFlight;
            // An early read that is slower than a later one is exactly the
            // case that reorders results when nothing guards the query.
            await Future<void>.delayed(Duration(seconds: 12 - id));
            inFlight--;
            completions.add(id);
          },
        );

        loop.start();
        async.elapse(const Duration(seconds: 60));
        loop.dispose();

        expect(peakInFlight, 1);
        expect(completions.length, greaterThan(2));
        expect(
          completions,
          orderedEquals(List.generate(completions.length, (i) => i + 1)),
          reason: 'answers must land in the order they were asked for',
        );
      });
    });

    test('runNow during a read returns without starting a second one', () {
      fakeAsync((async) {
        final read = _ManualRead();
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: read.call,
        );

        loop.start();
        async.flushMicrotasks();

        var returned = false;
        unawaited(loop.runNow().then((_) => returned = true));
        async.flushMicrotasks();

        expect(read.started, 1);
        expect(returned, isTrue, reason: 'a dropped read must not hang');

        read.finishAll();
        loop.dispose();
        async.flushMicrotasks();
      });
    });
  });

  group('lifetime', () {
    test('a second start does not add a second timer', () {
      fakeAsync((async) {
        var reads = 0;
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: () async => reads++,
        );

        loop.start();
        loop.start();
        loop.start();
        async.flushMicrotasks();
        expect(reads, 1, reason: 'the repeat starts must not read again');

        async.elapse(const Duration(seconds: 5));
        expect(reads, 2, reason: 'three timers would have read three times');

        loop.dispose();
      });
    });

    test('start without immediate waits for the first tick', () {
      fakeAsync((async) {
        var reads = 0;
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: () async => reads++,
        );

        loop.start(immediate: false);
        async.flushMicrotasks();
        expect(reads, 0);

        async.elapse(const Duration(seconds: 5));
        expect(reads, 1);

        loop.dispose();
      });
    });

    test('stop schedules nothing more, and start resumes', () {
      fakeAsync((async) {
        var reads = 0;
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: () async => reads++,
        );

        loop.start();
        async.elapse(const Duration(seconds: 12));
        expect(reads, 3);

        loop.stop();
        async.elapse(const Duration(minutes: 5));
        expect(reads, 3);
        expect(loop.isRunning, isFalse);

        loop.start();
        async.flushMicrotasks();
        expect(reads, 4);

        loop.dispose();
      });
    });

    test('a read that throws does not stop the loop', () {
      fakeAsync((async) {
        var reads = 0;
        final errors = <Object>[];
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: () async {
            reads++;
            throw StateError('bridge error');
          },
          onError: (error, _) => errors.add(error),
        );

        loop.start();
        async.flushMicrotasks();
        // The loop owns the cadence, not the error policy: the read decides
        // what a failure means. A poll that died on the first failed bridge
        // call would leave the screen frozen until it was rebuilt.
        async.elapse(const Duration(seconds: 12));
        expect(reads, 3);
        expect(errors.length, 3);
        expect(loop.isReading, isFalse, reason: 'the guard must be released');

        loop.dispose();
      });
    });

    test('a tick error with no handler is reported, never dropped', () {
      final reported = <Object>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) => reported.add(details.exception);
      addTearDown(() => FlutterError.onError = previous);

      fakeAsync((async) {
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: () async => throw StateError('bridge error'),
          debugLabel: 'trips',
        );

        loop.start();
        async.elapse(const Duration(seconds: 6));
        loop.dispose();
      });

      // Swallowing this would hide a broken read for as long as the screen
      // lives; letting it escape would raise one unhandled zone error per tick.
      expect(reported, hasLength(2));
      expect(reported.first, isStateError);
    });

    test('an awaited runNow gives the error back to its caller', () {
      fakeAsync((async) {
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: () async => throw StateError('bridge error'),
        );

        Object? caught;
        unawaited(loop.runNow().catchError((Object error) => caught = error));
        async.flushMicrotasks();

        expect(caught, isStateError);
        loop.dispose();
      });
    });

    test('dispose stops the loop and refuses further reads', () {
      fakeAsync((async) {
        var reads = 0;
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: () async => reads++,
        );

        loop.start();
        async.flushMicrotasks();
        expect(reads, 1);

        loop.dispose();
        loop.dispose();
        async.elapse(const Duration(minutes: 5));
        unawaited(loop.runNow());
        async.flushMicrotasks();

        expect(reads, 1);
      });
    });
  });

  group('a group shares one lifetime', () {
    test('start and stop reach every loop', () {
      fakeAsync((async) {
        var fast = 0;
        var slow = 0;
        final group = PollLoopGroup([
          PollLoop(
            interval: const Duration(seconds: 1),
            read: () async => fast++,
          ),
          PollLoop(
            interval: const Duration(seconds: 5),
            read: () async => slow++,
          ),
        ]);

        group.start();
        async.elapse(const Duration(seconds: 5));
        expect(fast, 6);
        expect(slow, 2);

        group.stop();
        async.elapse(const Duration(minutes: 1));
        expect(fast, 6);
        expect(slow, 2);

        group.dispose();
      });
    });

    test('dispose reaches every loop, so none can be forgotten', () {
      final group = PollLoopGroup([
        PollLoop(interval: const Duration(seconds: 1), read: () async {}),
        PollLoop(interval: const Duration(seconds: 5), read: () async {}),
      ]);

      group.start();
      expect(group.loops.every((loop) => loop.isRunning), isTrue);

      group.dispose();
      expect(group.loops.every((loop) => loop.isRunning), isFalse);
    });
  });

  group('activity lifecycle', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    tearDown(() {
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
    });

    test('a started loop stops ticking when the activity pauses', () {
      fakeAsync((async) {
        var reads = 0;
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: () async => reads++,
        );
        loop.start();
        async.flushMicrotasks();
        expect(reads, 1);
        expect(loop.isRunning, isTrue);

        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.paused,
        );
        async.elapse(const Duration(minutes: 1));
        expect(reads, 1, reason: 'a paused activity must not keep polling');
        expect(loop.isRunning, isTrue, reason: 'pause is not stop');

        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        async.flushMicrotasks();
        expect(reads, 2, reason: 'resume must read at once');

        loop.dispose();
      });
    });

    test('a stopped loop stays stopped after resume', () {
      fakeAsync((async) {
        var reads = 0;
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: () async => reads++,
        );
        loop.start();
        async.flushMicrotasks();
        loop.stop();

        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.paused,
        );
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        async.elapse(const Duration(minutes: 1));
        expect(reads, 1);
        expect(loop.isRunning, isFalse);

        loop.dispose();
      });
    });

    test('a hidden activity stops the tick, like a paused one', () {
      fakeAsync((async) {
        var reads = 0;
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: () async => reads++,
        );
        loop.start();
        async.flushMicrotasks();
        expect(reads, 1);

        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.hidden,
        );
        async.elapse(const Duration(minutes: 1));
        expect(reads, 1, reason: 'hidden is off screen, like paused');

        loop.dispose();
      });
    });

    test('a visible but unfocused activity keeps polling', () {
      fakeAsync((async) {
        var reads = 0;
        final loop = PollLoop(
          interval: const Duration(seconds: 5),
          read: () async => reads++,
        );
        loop.start();
        async.flushMicrotasks();
        expect(reads, 1);

        // The notification drawer, a system dialog, and this head unit's
        // split screen all take focus without taking the display. A card the
        // reader can still see must not freeze.
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(reads, 2, reason: 'a visible activity keeps its tick');

        // Regaining focus must not read again: the timer was never disarmed,
        // so an immediate read here would be a second one in the same frame
        // as any screen that restarts its own loops on resume.
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        async.flushMicrotasks();
        expect(reads, 2, reason: 'an armed loop does not re-read on focus');

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(reads, 3, reason: 'the tick survives the focus change');

        loop.dispose();
      });
    });
  });
}
