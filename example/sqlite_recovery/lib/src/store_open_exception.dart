/// Safe categories for failures to initialize or open the example database.
enum SqliteStoreOpenFailure {
  /// Explicit creation cannot replace an existing file.
  alreadyExists,

  /// Recovery cannot create a missing database.
  missingDatabase,

  /// An existing file has no supported initialized schema.
  invalidSchema,

  /// The database belongs to another application or format version.
  unsupportedFormat,

  /// The runtime cannot provide the required WAL/FULL configuration.
  configuration,

  /// The file or native database could not be accessed.
  unavailable,
}

/// Opening failed without retaining paths, SQL parameters, or native errors.
final class SqliteStoreOpenException implements Exception {
  /// Creates a safe opening failure.
  const SqliteStoreOpenException(this.reason);

  /// The category, without database contents.
  final SqliteStoreOpenFailure reason;

  @override
  String toString() => 'SqliteStoreOpenException(${reason.name})';
}
