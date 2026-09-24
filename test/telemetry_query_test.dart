import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_core/telemetry_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what a screen may draw', () {
    test('a first read is the only state that deserves a full spinner', () {
      const first = Loadable<int>.loading();
      final refresh = const Loadable<int>.ready(7).loading();

      expect(first.isFirstLoad, isTrue);
      expect(refresh.isLoading, isTrue);
      expect(
        refresh.isFirstLoad,
        isFalse,
        reason: 'a refresh must not blank a screen the reader is looking at',
      );
      expect(refresh.value, 7);
    });

    test('a failed refresh keeps the value it failed over', () {
      const failure = Loadable<int>.failed(FormatException('x'), value: 7);

      expect(failure.value, 7);
      expect(failure.isEmptyFailure, isFalse);
      expect(failure.isLoading, isFalse);
    });

    test('a failure with nothing behind it is an empty failure', () {
      const failure = Loadable<int>.failed(FormatException('x'));

      expect(failure.isEmptyFailure, isTrue);
      expect(failure.value, isNull);
    });

    test('a bridge failure shows its code, which is what names the fault', () {
      final failure = Loadable<int>.failed(
        PlatformException(code: 'no-car', message: 'CarPropertyManager absent'),
      );

      expect(failure.errorMessage, 'no-car: CarPropertyManager absent');
    });

    test('a bridge failure with no message still names its code', () {
      expect(
        describeBridgeError(PlatformException(code: 'no-car')),
        'no-car: bridge error',
      );
    });
  });

  group('the answer to a replaced question', () {
    test('is dropped when the question changed while it was in flight', () {
      fakeAsync((async) {
        var range = '7d';
        final completers = <String, Completer<String>>{};
        final query = TelemetryQuery<String>(
          read: () {
            final asked = range;
            final completer = Completer<String>();
            completers[asked] = completer;
            return completer.future;
          },
        );

        unawaited(query.refresh());
        async.flushMicrotasks();

        // The reader switches range. The 7d read is still out.
        range = '30d';
        unawaited(query.ask());
        async.flushMicrotasks();

        completers['30d']!.complete('thirty days');
        async.flushMicrotasks();
        expect(query.value, 'thirty days');

        // The old answer lands last. Painting it now would put the previous
        // range's data under the new range's label.
        completers['7d']!.complete('seven days');
        async.flushMicrotasks();
        expect(query.value, 'thirty days');

        query.dispose();
      });
    });

    test('ask clears the value first, then reads the new question', () {
      fakeAsync((async) {
        var answer = 7;
        final query = TelemetryQuery<int>(read: () async => answer);

        unawaited(query.refresh());
        async.flushMicrotasks();
        expect(query.value, 7);

        answer = 30;
        final pending = query.ask();
        // Cleared before the read lands: the old answer belongs to the old
        // question and must not sit under the new label while it is read.
        expect(query.value, isNull);
        expect(query.state.isFirstLoad, isTrue);

        unawaited(pending);
        async.flushMicrotasks();
        expect(query.value, 30);

        query.dispose();
      });
    });

    test('ask is not dropped when a read is already in flight', () {
      fakeAsync((async) {
        var reads = 0;
        final completers = <Completer<int>>[];
        final query = TelemetryQuery<int>(
          read: () {
            reads++;
            final completer = Completer<int>();
            completers.add(completer);
            return completer.future;
          },
        );

        unawaited(query.refresh());
        async.flushMicrotasks();
        expect(reads, 1);

        // Waiting for the previous question to answer would leave the screen
        // loading with nothing on its way for it.
        unawaited(query.ask());
        async.flushMicrotasks();
        expect(reads, 2);

        query.dispose();
      });
    });
  });

  group('reading', () {
    test('a tick never overlaps another tick', () {
      fakeAsync((async) {
        var reads = 0;
        final completers = <Completer<int>>[];
        final query = TelemetryQuery<int>(
          interval: const Duration(seconds: 5),
          read: () {
            reads++;
            final completer = Completer<int>();
            completers.add(completer);
            return completer.future;
          },
        );

        query.start();
        async.elapse(const Duration(seconds: 16));
        expect(reads, 1);

        completers.single.complete(1);
        async.elapse(const Duration(seconds: 5));
        expect(reads, 2);

        query.dispose();
      });
    });

    test('a background tick does not make the screen look busy', () {
      fakeAsync((async) {
        final completers = <Completer<int>>[];
        final query = TelemetryQuery<int>(
          interval: const Duration(seconds: 5),
          read: () {
            final completer = Completer<int>();
            completers.add(completer);
            return completer.future;
          },
        );

        query.start();
        async.flushMicrotasks();
        completers.last.complete(7);
        async.flushMicrotasks();
        expect(query.state.isLoading, isFalse);

        async.elapse(const Duration(seconds: 5));
        expect(
          query.state.isLoading,
          isFalse,
          reason: 'the 5s tick is not a user action and must not show as one',
        );
        expect(query.value, 7);

        query.dispose();
      });
    });

    test('an asked-for refresh does show as busy, over the old value', () {
      fakeAsync((async) {
        final completers = <Completer<int>>[];
        final query = TelemetryQuery<int>(
          read: () {
            final completer = Completer<int>();
            completers.add(completer);
            return completer.future;
          },
        );

        unawaited(query.refresh());
        async.flushMicrotasks();
        completers.last.complete(7);
        async.flushMicrotasks();

        unawaited(query.refresh(showLoading: true));
        async.flushMicrotasks();
        expect(query.state.isLoading, isTrue);
        expect(query.value, 7);
        expect(query.state.isFirstLoad, isFalse);

        query.dispose();
      });
    });

    test('a failed read keeps the last good value and names the fault', () {
      fakeAsync((async) {
        var fail = false;
        final query = TelemetryQuery<int>(
          read: () async {
            if (fail) throw PlatformException(code: 'no-car');
            return 7;
          },
        );

        unawaited(query.refresh());
        async.flushMicrotasks();
        expect(query.value, 7);

        fail = true;
        unawaited(query.refresh());
        async.flushMicrotasks();

        expect(query.value, 7, reason: 'a failed poll is not an empty car');
        expect(query.state.errorMessage, startsWith('no-car'));
        expect(query.state.isEmptyFailure, isFalse);

        query.dispose();
      });
    });

    test(
      'a read that fails first shows the failure with nothing behind it',
      () {
        fakeAsync((async) {
          final query = TelemetryQuery<int>(
            read: () async => throw PlatformException(code: 'no-car'),
          );

          unawaited(query.refresh());
          async.flushMicrotasks();

          expect(query.state.isEmptyFailure, isTrue);
          expect(query.value, isNull);

          query.dispose();
        });
      },
    );

    test('listeners are notified once per state change, never for a no-op', () {
      fakeAsync((async) {
        var notifications = 0;
        final query = TelemetryQuery<int>(
          interval: const Duration(seconds: 5),
          read: () async => 7,
        );
        query.addListener(() => notifications++);

        query.start();
        async.flushMicrotasks();
        expect(notifications, 1);

        // The same answer twice is not news, and a screen that rebuilt for it
        // would rebuild on every tick of an unchanging car.
        async.elapse(const Duration(seconds: 15));
        expect(notifications, 1);

        query.dispose();
      });
    });

    test('a read landing after dispose does not notify', () {
      fakeAsync((async) {
        final completer = Completer<int>();
        final query = TelemetryQuery<int>(read: () => completer.future);

        var notifications = 0;
        query.addListener(() => notifications++);

        unawaited(query.refresh());
        async.flushMicrotasks();
        query.dispose();

        completer.complete(7);
        async.flushMicrotasks();

        expect(notifications, 0);
      });
    });

    test('a started query stops polling when the activity pauses', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      addTearDown(() {
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });

      fakeAsync((async) {
        var reads = 0;
        final query = TelemetryQuery<int>(
          interval: const Duration(seconds: 5),
          read: () async => ++reads,
        );
        query.start();
        async.flushMicrotasks();
        expect(reads, 1);

        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.paused,
        );
        async.elapse(const Duration(minutes: 1));
        expect(reads, 1);

        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        async.flushMicrotasks();
        expect(reads, 2);

        query.dispose();
      });
    });
  });

  group('push instead of poll', () {
    test('a push reads at once, without waiting for the tick', () {
      fakeAsync((async) {
        var reads = 0;
        final pushes = StreamController<void>.broadcast();
        final query = TelemetryQuery<int>(
          interval: const Duration(minutes: 5),
          read: () async => ++reads,
          refreshOn: pushes.stream,
        );

        query.start();
        async.flushMicrotasks();
        expect(reads, 1);

        pushes.add(null);
        async.flushMicrotasks();
        expect(reads, 2, reason: 'the car said a session was written');

        // Nothing else happens on its own for a long time: that is the point.
        async.elapse(const Duration(minutes: 4));
        expect(reads, 2);

        query.dispose();
        unawaited(pushes.close());
      });
    });

    test('polling can be paused while the push keeps working', () {
      fakeAsync((async) {
        var reads = 0;
        final pushes = StreamController<void>.broadcast();
        final query = TelemetryQuery<int>(
          interval: const Duration(seconds: 5),
          read: () async => ++reads,
          refreshOn: pushes.stream,
        );

        query.start();
        async.flushMicrotasks();
        expect(reads, 1);

        // Nothing is open, so there is nothing a tick could find.
        query.setPolling(false);
        async.elapse(const Duration(minutes: 1));
        expect(reads, 1);

        pushes.add(null);
        async.flushMicrotasks();
        expect(
          reads,
          2,
          reason: 'the push is not the tick and must survive it',
        );

        // A session opened: the row now carries values only frames report.
        query.setPolling(true);
        async.elapse(const Duration(seconds: 10));
        expect(reads, 4);

        query.dispose();
        unawaited(pushes.close());
      });
    });

    test('a broken push leaves the tick as the fallback', () {
      fakeAsync((async) {
        var reads = 0;
        final pushes = StreamController<void>.broadcast();
        final query = TelemetryQuery<int>(
          interval: const Duration(seconds: 5),
          read: () async => ++reads,
          refreshOn: pushes.stream,
        );

        query.start();
        async.flushMicrotasks();
        pushes.addError(StateError('channel gone'));
        async.flushMicrotasks();

        // An event channel that fails must not take the list down with it.
        async.elapse(const Duration(seconds: 10));
        expect(reads, 3);

        query.dispose();
        unawaited(pushes.close());
      });
    });

    test('dispose stops listening, so a late push cannot read', () {
      fakeAsync((async) {
        var reads = 0;
        final pushes = StreamController<void>.broadcast();
        final query = TelemetryQuery<int>(
          interval: const Duration(minutes: 5),
          read: () async => ++reads,
          refreshOn: pushes.stream,
        );

        query.start();
        async.flushMicrotasks();
        query.dispose();

        pushes.add(null);
        async.flushMicrotasks();

        expect(reads, 1);
        unawaited(pushes.close());
      });
    });

    group('put', () {
      test('a write read-back becomes the answer without a read', () {
        fakeAsync((async) {
          var reads = 0;
          final query = TelemetryQuery<int>(
            interval: const Duration(minutes: 5),
            read: () async => ++reads,
          );

          query.start();
          async.flushMicrotasks();
          expect(query.value, 1);

          // The car answered a write with its own value. Reading again to
          // learn what the write already reported is the round trip this
          // avoids.
          query.put(99);

          expect(query.value, 99);
          expect(reads, 1);
          query.dispose();
        });
      });

      test('a read already in flight cannot land on top of a read-back', () {
        fakeAsync((async) {
          final gate = Completer<int>();
          final query = TelemetryQuery<int>(
            interval: const Duration(minutes: 5),
            read: () => gate.future,
          );

          query.start();
          async.flushMicrotasks();

          // The write's read-back is newer than the read that is still out,
          // whichever of the two the car answers first.
          query.put(42);
          gate.complete(7);
          async.flushMicrotasks();

          expect(query.value, 42);
          query.dispose();
        });
      });

      test('the state is ready, so a previous failure stops being shown', () {
        fakeAsync((async) {
          var fail = true;
          final query = TelemetryQuery<int>(
            interval: const Duration(minutes: 5),
            read: () async {
              if (fail) throw StateError('bridge down');
              return 1;
            },
          );

          query.start();
          async.flushMicrotasks();
          expect(query.state.error, isNotNull);

          fail = false;
          query.put(5);

          expect(query.state.error, isNull);
          expect(query.state.isLoading, isFalse);
          query.dispose();
        });
      });
    });
  });
}
