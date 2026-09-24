import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/journey_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_archive.dart';

void main() {
  late CompanionArchive archive;
  late JourneyStore store;

  setUp(() async {
    archive = await memoryArchive();
    var now = 1000;
    store = JourneyStore(archive, nowMillis: () => now += 10);
  });

  Map<String, Object?> carRow({
    String id = 'j1',
    int updatedAt = 500,
    String origin = 'car',
    String name = 'Ida',
    int? deletedAt,
  }) => {
    'id': id,
    'name': name,
    'startedAtUtcMillis': 100,
    'endedAtUtcMillis': 200,
    'note': null,
    'createdAtUtcMillis': 90,
    'updatedAtUtcMillis': updatedAt,
    'origin': origin,
    'hlcMillis': updatedAt,
    'hlcCounter': 0,
    'hlcDeviceId': origin,
    'deletedAtUtcMillis': deletedAt,
  };

  group('JourneyStore', () {
    test('create writes a phone row and queues it for the car', () async {
      final journey = await store.create(
        name: 'Férias',
        startedAtUtcMillis: 100,
        endedAtUtcMillis: 200,
        note: ' serra ',
      );
      expect(journey.note, 'serra');
      expect(journey.origin, 'phone');
      expect(await store.journeys(), [journey]);

      final pending = await archive.database.pendingAnnotationPush();
      expect(pending, hasLength(1));
      expect(pending.single.stream, 'journeys');
      expect(pending.single.row['id'], journey.id);
    });

    test('update keeps the identity and moves the stamp', () async {
      final created = await store.create(
        name: 'Férias',
        startedAtUtcMillis: 100,
        endedAtUtcMillis: 200,
      );
      final updated = await store.update(created, name: 'Volta');
      expect(updated.id, created.id);
      expect(updated.name, 'Volta');
      expect(
        updated.updatedAtUtcMillis,
        greaterThan(created.updatedAtUtcMillis),
      );
      expect(await store.journeys(), [updated]);
    });

    test('update refuses an inverted window and a blank name', () async {
      final created = await store.create(
        name: 'Férias',
        startedAtUtcMillis: 100,
        endedAtUtcMillis: 200,
      );
      expect(
        () => store.update(created, startedAtUtcMillis: 300),
        throwsArgumentError,
      );
      expect(() => store.update(created, name: '  '), throwsArgumentError);
    });

    test('delete stamps a tombstone and hides the row', () async {
      final created = await store.create(
        name: 'Férias',
        startedAtUtcMillis: 100,
        endedAtUtcMillis: 200,
      );
      await store.delete(created.id);
      expect(await store.journeys(), isEmpty);
      expect((await store.journey(created.id))!.deleted, isTrue);

      final pushes = await archive.database.pendingAnnotationPush();
      expect(
        pushes.where((item) => item.row['id'] == created.id),
        hasLength(2),
      );
      expect(pushes.last.row['deletedAtUtcMillis'], isNotNull);
    });
  });

  group('journey annotation merge', () {
    test('a pulled car row lands', () async {
      await archive.upsertJourney(carRow());
      final rows = await archive.database.allJourneys();
      expect(rows, hasLength(1));
      expect(rows.single['name'], 'Ida');
    });

    test('an older pull loses to a newer local edit', () async {
      await store.create(
        name: 'Local',
        startedAtUtcMillis: 1,
        endedAtUtcMillis: 2,
      );
      final id =
          (await archive.database.pendingAnnotationPush()).single.row['id']
              as String;

      await archive.upsertJourney(carRow(id: id, updatedAt: 5));

      final rows = await archive.database.allJourneys();
      expect(rows.single['name'], 'Local');
    });

    test('a newer car row wins over a stale replica', () async {
      await archive.upsertJourney(carRow(updatedAt: 900, name: 'Novo'));
      await archive.upsertJourney(carRow(updatedAt: 400, name: 'Velho'));
      expect((await archive.database.allJourneys()).single['name'], 'Novo');

      await archive.upsertJourney(carRow(updatedAt: 950, name: 'Mais novo'));
      expect(
        (await archive.database.allJourneys()).single['name'],
        'Mais novo',
      );
    });

    test('a malformed row is refused', () async {
      final applied = await archive.upsertJourney({
        ...carRow(),
        'endedAtUtcMillis': 50,
        'startedAtUtcMillis': 100,
      });
      expect(applied, isFalse);
      expect(await archive.database.allJourneys(), isEmpty);
    });

    test('a tombstone from the car deletes a live row', () async {
      await archive.upsertJourney(carRow());
      await archive.upsertJourney(carRow(deletedAt: 700, updatedAt: 700));
      final rows = await archive.database.allJourneys();
      expect(rows.single['deletedAtUtcMillis'], 700);
    });
  });
}
