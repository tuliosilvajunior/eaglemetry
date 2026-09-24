import 'package:flutter_test/flutter_test.dart';
import 'package:capy_energy/core/live_trip_can.dart';
import 'package:capy_energy/core/live_trip_can_hub.dart';

void main() {
  test('acquire starts the holder count and release stops at zero', () async {
    final hub = LiveTripCanHub();
    addTearDown(hub.dispose);

    expect(hub.holders, 0);
    await hub.acquire();
    expect(hub.holders, 1);
    await hub.acquire();
    expect(hub.holders, 2);
    hub.release();
    expect(hub.holders, 1);
    hub.release();
    expect(hub.holders, 0);
    hub.release();
    expect(hub.holders, 0);
  });

  test('listeners receive a dispatched sample', () {
    final hub = LiveTripCanHub();
    addTearDown(hub.dispose);

    final seen = <int>[];
    hub.addListener((_, now) => seen.add(now));
    hub.debugDispatch(
      LiveTripCanState(entries: const [], retainActivityHistory: false),
      42,
    );
    expect(seen, [42]);
  });

  test('removing a listener stops further dispatches', () {
    final hub = LiveTripCanHub();
    addTearDown(hub.dispose);

    final seen = <int>[];
    void listen(LiveTripCanState _, int now) => seen.add(now);
    hub.addListener(listen);
    hub.debugDispatch(
      LiveTripCanState(entries: const [], retainActivityHistory: false),
      1,
    );
    hub.removeListener(listen);
    hub.debugDispatch(
      LiveTripCanState(entries: const [], retainActivityHistory: false),
      2,
    );
    expect(seen, [1]);
  });
}
