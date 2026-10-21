import 'operation_exception.dart';
import 'operation_identity.dart';

/// Semantic evidence supplied by an application backend adapter.
///
/// Before creating an authoritative observation, the adapter must verify the
/// backend contract and response identity. These types cannot authenticate a
/// backend response or infer authority from an HTTP status code.
sealed class BackendObservation {
  const BackendObservation({required this.identity});

  /// The complete identity against which the adapter validated this result.
  final OperationIdentity identity;

  /// Whether this observation asserts an authoritative final business outcome.
  bool get isAuthoritative => switch (this) {
    OperationSucceeded() || OperationRejected() => true,
    OperationPending() || OperationUnknown() || LookupUnavailable() => false,
  };

  @override
  String toString() => runtimeType.toString();
}

/// Authoritative confirmation that the business operation succeeded.
final class OperationSucceeded extends BackendObservation {
  /// Creates a success observation with optional safe, opaque backend metadata.
  OperationSucceeded({required super.identity, this.backendReference}) {
    _validateOptionalMetadata('backendReference', backendReference);
  }

  /// An optional nonblank reference; do not use sensitive payload data here.
  final String? backendReference;
}

/// Authoritative confirmation of a final business rejection.
///
/// A timeout, generic HTTP error, or HTTP 401 is never sufficient authority.
final class OperationRejected extends BackendObservation {
  /// Creates a rejection with an optional safe machine-readable code.
  OperationRejected({required super.identity, this.code}) {
    _validateOptionalMetadata('code', code);
  }

  /// An optional nonblank rejection code, not a raw server error body.
  final String? code;
}

/// The backend reports that the operation is still processing.
final class OperationPending extends BackendObservation {
  /// Creates a nonfinal processing observation.
  const OperationPending({required super.identity});
}

/// No authoritative business outcome can be concluded.
///
/// Examples include a lost submission response or a status lookup returning
/// 404 without a backend guarantee that explains its meaning.
final class OperationUnknown extends BackendObservation {
  /// Creates an observation that leaves the business outcome unresolved.
  const OperationUnknown({required super.identity});
}

/// Why an authoritative status lookup could not be completed.
enum LookupFailureReason {
  /// Credentials are missing or expired, including an HTTP 401 response.
  authenticationRequired,

  /// A timeout, connection reset, or other transport failure prevented lookup.
  transportFailure,

  /// The authoritative status service is temporarily unavailable.
  serviceUnavailable,
}

/// Recoverable inability to obtain authoritative status, not business rejection.
final class LookupUnavailable extends BackendObservation {
  /// Creates an unavailable lookup observation without credentials or raw errors.
  const LookupUnavailable({required super.identity, required this.reason});

  /// The semantic recovery condition reported to the application.
  final LookupFailureReason reason;
}

void _validateOptionalMetadata(String field, String? value) {
  if (value != null && value.trim().isEmpty) {
    throw InvalidBackendObservationException(field, 'must be null or nonblank');
  }
}
