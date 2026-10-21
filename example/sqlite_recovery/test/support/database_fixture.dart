import 'dart:io';

import 'package:operation_recovery_sqlite_example/sqlite_operation_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Directory temporaryDatabaseDirectory() =>
    Directory.systemTemp.createTempSync('operation_recovery_sqlite_');

// Recover and explicitly checkpoint committed WAL before injecting damage into
// the main file. Bare open/close is lazy and does not guarantee either action.
void checkpointDatabase(String path) {
  final db = sqlite3.open(path, mode: OpenMode.readWrite);
  try {
    db.execute('PRAGMA busy_timeout = 5000');
    final result = db.select('PRAGMA wal_checkpoint(TRUNCATE)').single;
    expect(result.values.toList(), [
      0,
      0,
      0,
    ], reason: 'Checkpoint must complete');
  } finally {
    db.close();
  }
  expect(
    File('$path-wal').existsSync() ? File('$path-wal').lengthSync() : 0,
    0,
    reason: 'Corruption fixture must not retain recoverable WAL frames',
  );
}

void removeDatabaseDirectory(Directory directory) {
  if (!directory.existsSync()) return;
  final parent = directory.parent.resolveSymbolicLinksSync();
  final expected = Directory.systemTemp.resolveSymbolicLinksSync();
  final name = directory.uri.pathSegments.where((part) => part.isNotEmpty).last;
  if (parent != expected || !name.startsWith('operation_recovery_sqlite_')) {
    throw StateError(
      'Refusing to remove a directory outside the owned temp root',
    );
  }
  directory.deleteSync(recursive: true);
}

final class DatabaseFixture {
  DatabaseFixture() {
    directory = temporaryDatabaseDirectory();
    path = '${directory.path}${Platform.pathSeparator}operations.sqlite';
    try {
      store = SqliteOperationStore.create(path);
    } catch (_) {
      removeDatabaseDirectory(directory);
      rethrow;
    }
    addTearDown(() {
      try {
        store.close();
      } finally {
        removeDatabaseDirectory(directory);
      }
    });
  }

  late final Directory directory;
  late final String path;
  late SqliteOperationStore store;

  void reopen() {
    store.close();
    store = SqliteOperationStore.open(path);
  }

  void sql(void Function(Database db) action) {
    final db = sqlite3.open(path, mode: OpenMode.readWrite);
    try {
      action(db);
    } finally {
      db.close();
    }
  }
}
