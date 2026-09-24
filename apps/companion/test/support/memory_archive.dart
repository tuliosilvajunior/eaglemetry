import 'package:capy_companion/sync/companion_archive.dart';
import 'package:capy_companion/sync/companion_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An archive on an in-memory database.
///
/// The store is SQLite on the phone, so a test that wants the archive's rules
/// needs a database rather than a stub: the ordering, the paging and the
/// staged-frame transaction are all in the SQL.
Future<CompanionArchive> memoryArchive() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final archive = CompanionArchive(
    await CompanionDatabase.open(inMemoryDatabasePath, singleInstance: false),
  );
  await archive.load();
  return archive;
}
