import 'dart:io';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:sqlite3/sqlite3.dart';

import 'record_codec.dart';
import 'store_open_exception.dart';

const _applicationId = 0x4f524543;
const _schema =
    '''
CREATE TABLE operations (
  operation_id TEXT NOT NULL PRIMARY KEY COLLATE BINARY,
  scope TEXT NOT NULL COLLATE BINARY,
  operation_type TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_fingerprint TEXT NOT NULL,
  record_schema_version INTEGER NOT NULL CHECK(record_schema_version >= 1),
  state TEXT NOT NULL CHECK(state IN
    ('prepared','awaiting_outcome','needs_attention','succeeded','rejected')),
  record_version INTEGER NOT NULL CHECK(record_version >= 0),
  created_at_us INTEGER NOT NULL,
  updated_at_us INTEGER NOT NULL CHECK(updated_at_us >= created_at_us),
  observation_kind TEXT,
  backend_reference TEXT,
  rejection_code TEXT,
  lookup_failure_reason TEXT,
  cycle_attempts INTEGER NOT NULL CHECK(cycle_attempts >= 0),
  total_attempts INTEGER NOT NULL CHECK(total_attempts >= cycle_attempts),
  last_attempt_at_us INTEGER,
  next_check_at_us INTEGER
) STRICT;
CREATE INDEX operations_by_scope ON operations(scope);
PRAGMA application_id = $_applicationId;
PRAGMA user_version = 1;
''';

/// Practical synchronous SQLite reference behind the asynchronous store port.
///
/// Requires a local file, SQLite >= 3.51.3, WAL, and synchronous=FULL. Acknowledges
/// COMMIT, never a proposed snapshot. Transactions contain no awaits or callbacks.
/// Database CAS is not ownership of business handlers across coordinators.
final class SqliteOperationStore implements OperationStore {
  SqliteOperationStore._(this._database);

  /// Exclusively creates and initializes a new database, never replacing a file.
  factory SqliteOperationStore.create(String path) {
    _validatePath(path);
    try {
      if ([path, '$path-wal', '$path-shm'].any(
        (candidate) =>
            FileSystemEntity.typeSync(candidate, followLinks: false) !=
            FileSystemEntityType.notFound,
      )) {
        throw const SqliteStoreOpenException(
          SqliteStoreOpenFailure.alreadyExists,
        );
      }
      File(path).createSync(exclusive: true);
    } on FileSystemException {
      throw const SqliteStoreOpenException(SqliteStoreOpenFailure.unavailable);
    }
    return _connect(path, initialize: true);
  }

  /// Opens an existing initialized database; never creates, resets, or repairs it.
  factory SqliteOperationStore.open(String path) {
    _validatePath(path);
    try {
      if (!File(path).existsSync()) {
        throw const SqliteStoreOpenException(
          SqliteStoreOpenFailure.missingDatabase,
        );
      }
    } on FileSystemException {
      throw const SqliteStoreOpenException(SqliteStoreOpenFailure.unavailable);
    }
    return _connect(path, initialize: false);
  }

  final Database _database;
  bool _closed = false;

  /// Effective connection settings for diagnostics, without paths or row data.
  Map<String, Object?> get configuration {
    if (_closed) throw const OperationStoreReadException();
    try {
      return Map<String, Object?>.unmodifiable({
        'sqlite_version': _database
            .select('SELECT sqlite_version()')
            .single
            .values
            .single,
        'journal_mode': _database
            .select('PRAGMA journal_mode')
            .single
            .values
            .single,
        'synchronous': _database
            .select('PRAGMA synchronous')
            .single
            .values
            .single,
        'busy_timeout': _database
            .select('PRAGMA busy_timeout')
            .single
            .values
            .single,
      });
    } on SqliteException {
      throw const OperationStoreReadException();
    }
  }

  static void _validatePath(String path) {
    if (path.trim().isEmpty || path == ':memory:') {
      throw const SqliteStoreOpenException(
        SqliteStoreOpenFailure.configuration,
      );
    }
  }

  static SqliteOperationStore _connect(
    String path, {
    required bool initialize,
  }) {
    Database? database;
    try {
      final db = database = sqlite3.open(path, mode: OpenMode.readWrite);
      // Even the first schema read may need WAL recovery or race another
      // connection's final checkpoint. Install bounded waiting before any read.
      db.execute('PRAGMA busy_timeout = 5000');
      if (!initialize) _validateSchema(db);
      final parts =
          (db.select('SELECT sqlite_version()').single.values.single as String)
              .split('.')
              .map(int.parse)
              .toList();
      if (parts[0] < 3 ||
          (parts[0] == 3 &&
              (parts[1] < 51 || (parts[1] == 51 && parts[2] < 3)))) {
        throw const SqliteStoreOpenException(
          SqliteStoreOpenFailure.configuration,
        );
      }
      var journal = db.select('PRAGMA journal_mode').single.values.single;
      if (journal != 'wal') {
        journal = db.select('PRAGMA journal_mode = WAL').single.values.single;
      }
      db.execute('PRAGMA synchronous = FULL');
      if (journal != 'wal' ||
          db.select('PRAGMA synchronous').single.values.single != 2 ||
          db.select('PRAGMA busy_timeout').single.values.single != 5000) {
        throw const SqliteStoreOpenException(
          SqliteStoreOpenFailure.configuration,
        );
      }
      if (initialize) {
        db.execute('BEGIN IMMEDIATE');
        db.execute(_schema);
        db.execute('COMMIT');
      }
      _validateSchema(db);
      return SqliteOperationStore._(db);
    } catch (error) {
      if (database != null) {
        try {
          if (!database.autocommit) database.execute('ROLLBACK');
        } catch (_) {
          // No usable adapter escapes a failed open.
        }
        try {
          database.close();
        } catch (_) {
          // Preserve the safe original opening error.
        }
      }
      if (error is SqliteStoreOpenException) rethrow;
      throw const SqliteStoreOpenException(SqliteStoreOpenFailure.unavailable);
    }
  }

  static void _validateSchema(Database db) {
    final version = db.select('PRAGMA user_version').single.values.single;
    final app = db.select('PRAGMA application_id').single.values.single;
    if (version == 0 && app == 0) {
      throw const SqliteStoreOpenException(
        SqliteStoreOpenFailure.invalidSchema,
      );
    }
    if (version != 1 || app != _applicationId) {
      throw const SqliteStoreOpenException(
        SqliteStoreOpenFailure.unsupportedFormat,
      );
    }
    final objects = db.select(
      "SELECT name, type FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
    );
    if (objects.length != 2 ||
        !objects.any(
          (row) => row['name'] == 'operations' && row['type'] == 'table',
        ) ||
        !objects.any(
          (row) =>
              row['name'] == 'operations_by_scope' && row['type'] == 'index',
        )) {
      throw const SqliteStoreOpenException(
        SqliteStoreOpenFailure.invalidSchema,
      );
    }
    final columns = db.select('PRAGMA table_info(operations)');
    if (columns.length != recordColumns.length) {
      throw const SqliteStoreOpenException(
        SqliteStoreOpenFailure.invalidSchema,
      );
    }
    for (var index = 0; index < recordColumns.length; index++) {
      final name = recordColumns[index];
      final row = columns[index];
      if (row['name'] != name ||
          row['type'] != (integerColumns.contains(name) ? 'INTEGER' : 'TEXT') ||
          row['notnull'] != (nullableColumns.contains(name) ? 0 : 1) ||
          row['pk'] != (index == 0 ? 1 : 0)) {
        throw const SqliteStoreOpenException(
          SqliteStoreOpenFailure.invalidSchema,
        );
      }
    }
    final scopeIndex = db.select('PRAGMA index_info(operations_by_scope)');
    final table = db.select("PRAGMA table_list('operations')");
    if (scopeIndex.length != 1 ||
        scopeIndex.single['name'] != 'scope' ||
        table.single['strict'] != 1) {
      throw const SqliteStoreOpenException(
        SqliteStoreOpenFailure.invalidSchema,
      );
    }
    final scopeKeys = db
        .select('PRAGMA index_xinfo(operations_by_scope)')
        .where((row) => row['key'] == 1)
        .toList();
    final primary = db
        .select('PRAGMA index_list(operations)')
        .where((row) => row['origin'] == 'pk')
        .toList();
    if (scopeKeys.length != 1 ||
        scopeKeys.single['coll'] != 'BINARY' ||
        primary.length != 1) {
      throw const SqliteStoreOpenException(
        SqliteStoreOpenFailure.invalidSchema,
      );
    }
    // The generated PK index name comes from SQLite, never application input.
    final primaryName = primary.single['name']! as String;
    final primaryKeys = db
        .select('SELECT * FROM pragma_index_xinfo(?)', [primaryName])
        .where((row) => row['key'] == 1)
        .toList();
    if (primaryKeys.length != 1 ||
        primaryKeys.single['name'] != 'operation_id' ||
        primaryKeys.single['coll'] != 'BINARY') {
      throw const SqliteStoreOpenException(
        SqliteStoreOpenFailure.invalidSchema,
      );
    }
  }

  @override
  Future<OperationRecord?> read({
    required String id,
    required String scope,
  }) async {
    if (_closed) throw const OperationStoreReadException();
    try {
      final rows = _database.select(
        'SELECT * FROM operations WHERE operation_id = ? COLLATE BINARY AND scope = ? COLLATE BINARY',
        [id, scope],
      );
      return rows.isEmpty ? null : decodeRecord(rows.single);
    } on SqliteException {
      throw const OperationStoreReadException();
    }
  }

  @override
  Future<List<OperationRecord>> listUnresolved({required String scope}) async {
    if (_closed) throw const OperationStoreReadException();
    try {
      final records = _database
          .select('SELECT * FROM operations WHERE scope = ? COLLATE BINARY', [
            scope,
          ])
          .map(decodeRecord)
          .toList();
      return List<OperationRecord>.unmodifiable(
        records.where((record) => record.state.isUnresolved),
      );
    } on SqliteException {
      throw const OperationStoreReadException();
    }
  }

  @override
  Future<bool> createIfAbsent(OperationRecord record) async {
    if (record.state != OperationState.prepared || record.version != 0) {
      throw const InvalidOperationRecordException(
        'state',
        'creation requires a prepared version-zero snapshot',
      );
    }
    final values = encodeRecord(record);
    return _write(() {
      final existing = _existing(record.identity.id);
      if (existing != null) {
        existing.identity.requireMatch(record.identity);
        return false;
      }
      _database.execute(
        'INSERT INTO operations (${recordColumns.join(',')}) '
        'VALUES (${List.filled(recordColumns.length, '?').join(',')})',
        values,
      );
      return _oneRow();
    });
  }

  @override
  Future<bool> compareAndSwap(
    OperationRecord replacement, {
    required int expectedVersion,
  }) async {
    if (expectedVersion < 0 || replacement.version != expectedVersion + 1) {
      throw const InvalidOperationRecordException(
        'version',
        'replacement must advance a nonnegative expected version once',
      );
    }
    final values = encodeRecord(replacement);
    return _write(() {
      final existing = _existing(replacement.identity.id);
      if (existing == null) return false;
      existing.identity.requireMatch(replacement.identity);
      if (existing.version != expectedVersion) return false;
      if (existing.state.isTerminal) {
        throw IllegalOperationTransitionException(
          state: existing.state,
          action: 'compareAndSwap',
        );
      }
      if (replacement.createdAt != existing.createdAt) {
        throw const InvalidOperationRecordException(
          'createdAt',
          'must match the stored creation time',
        );
      }
      if (replacement.updatedAt.isBefore(existing.updatedAt)) {
        throw const InvalidOperationRecordException(
          'updatedAt',
          'must not precede the stored update time',
        );
      }
      _database.execute(
        'UPDATE operations SET '
        '${recordColumns.skip(5).map((name) => '$name = ?').join(',')} '
        'WHERE operation_id = ? AND scope = ? AND operation_type = ? '
        'AND idempotency_key = ? AND request_fingerprint = ? '
        "AND record_version = ? AND state NOT IN ('succeeded','rejected')",
        [...values.skip(5), ...values.take(5), expectedVersion],
      );
      return _oneRow();
    });
  }

  OperationRecord? _existing(String id) {
    final rows = _database.select(
      'SELECT * FROM operations WHERE operation_id = ? COLLATE BINARY',
      [id],
    );
    return rows.isEmpty ? null : decodeRecord(rows.single);
  }

  bool _oneRow() {
    final changed = _database.updatedRows;
    if (changed == 0) return false;
    if (changed != 1) throw StateError('Unexpected affected-row count');
    return true;
  }

  bool _write(bool Function() action) {
    if (_closed) {
      throw const OperationStoreWriteException(
        commitStatus: StoreCommitStatus.notCommitted,
      );
    }
    var commitAttempted = false;
    try {
      _database.execute('BEGIN IMMEDIATE');
      final changed = action();
      if (!changed) {
        _database.execute('ROLLBACK');
        return false;
      }
      commitAttempted = true;
      _database.execute('COMMIT');
      if (!_database.autocommit) throw StateError('Commit is not complete');
      return true;
    } catch (error) {
      var cleaned = false;
      try {
        if (!_database.autocommit) _database.execute('ROLLBACK');
        cleaned = _database.autocommit;
      } catch (_) {
        // An unusable connection cannot be reused to infer success.
      }
      if (commitAttempted || !cleaned) {
        try {
          close();
        } catch (_) {
          // The original uncertain invocation must still surface as unknown.
        }
      }
      if (cleaned && !commitAttempted && error is OperationRecoveryException) {
        rethrow;
      }
      throw OperationStoreWriteException(
        commitStatus: commitAttempted || !cleaned
            ? StoreCommitStatus.unknown
            : StoreCommitStatus.notCommitted,
      );
    }
  }

  /// Releases this connection. Drain the facade first; never deletes WAL files.
  void close() {
    if (_closed) return;
    _closed = true;
    _database.close();
  }
}
