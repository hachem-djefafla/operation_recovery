import '../domain/backend_observation.dart';
import '../domain/operation_identity.dart';

/// Account-bound integration for one operation type.
///
/// Configure network deadlines and disable write retries in the implementation.
/// Futures must settle. Validate backend response correlation before asserting
/// authority. Do not reenter the same coordinator/ID or await its shutdown.
abstract interface class OperationHandler<TRequest> {
  /// Performs one intentional submission using transient request data.
  Future<BackendObservation> submit(
    OperationIdentity identity,
    TRequest request,
  );

  /// Reads authoritative status only; it must never issue a business write.
  Future<BackendObservation> lookupStatus(OperationIdentity identity);
}
