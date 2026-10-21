/// File-backed WAL/FULL reference storage; no distributed handler ownership.
library;

export 'src/sqlite_operation_store.dart' show SqliteOperationStore;
export 'src/store_open_exception.dart'
    show SqliteStoreOpenException, SqliteStoreOpenFailure;
