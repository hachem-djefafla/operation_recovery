import 'operation_exception.dart';

/// Immutable, value-based identity of one intentional business operation.
///
/// IDs are unique within a store. Reusing an ID with a different scope, type,
/// key, or fingerprint is a conflict. Values are case-sensitive and preserved
/// exactly; the application owns fingerprint canonicalization and key creation.
final class OperationIdentity {
  /// Creates an identity, rejecting blank fields without retaining their values
  /// in validation errors.
  OperationIdentity({
    required this.id,
    required this.scope,
    required this.type,
    required this.idempotencyKey,
    required this.requestFingerprint,
  }) {
    for (final entry in {
      'id': id,
      'scope': scope,
      'type': type,
      'idempotencyKey': idempotencyKey,
      'requestFingerprint': requestFingerprint,
    }.entries) {
      if (entry.value.trim().isEmpty) {
        throw InvalidOperationRecordException(entry.key, 'must not be blank');
      }
    }
  }

  /// The stable, client-known operation ID.
  final String id;

  /// The immutable account or application boundary owning the operation.
  final String scope;

  /// The stable identifier of the operation's handler registration.
  final String type;

  /// The backend idempotency key; its retention is a backend responsibility.
  final String idempotencyKey;

  /// The application-generated fingerprint of the original business request.
  final String requestFingerprint;

  /// Throws if [candidate] attempts to change any identity component.
  void requireMatch(OperationIdentity candidate) {
    if (this != candidate) {
      throw const OperationIdentityConflictException();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is OperationIdentity &&
      id == other.id &&
      scope == other.scope &&
      type == other.type &&
      idempotencyKey == other.idempotencyKey &&
      requestFingerprint == other.requestFingerprint;

  @override
  int get hashCode =>
      Object.hash(id, scope, type, idempotencyKey, requestFingerprint);

  @override
  String toString() => 'OperationIdentity(<redacted>)';
}
