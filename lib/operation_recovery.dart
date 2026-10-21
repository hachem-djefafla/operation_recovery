/// Explicit submission and lookup-only recovery of uncertain operations.
///
/// Use a durable adapter for crash recovery. Memory provides only local atomicity.
/// Applications provide handlers and the authoritative backend contract.
library;

export 'src/application/operation_event.dart' show OperationEvent;
export 'src/application/operation_execution_exception.dart'
    show
        HandlerAction,
        InvalidOperationRegistrationException,
        InvalidOperationRequestException,
        OperationExecutionException,
        OperationHandlerException,
        OperationRecoveryClosedException;
export 'src/application/operation_recovery.dart' show OperationRecovery;
export 'src/application/reconciliation_result.dart'
    show ReconciliationCompleted, ReconciliationFailed, ReconciliationResult;
export 'src/application/recovery_coordinator.dart' show OperationRegistration;
export 'src/application/recovery_policy.dart' show RecoveryPolicy;

export 'src/domain/backend_observation.dart'
    show
        BackendObservation,
        LookupFailureReason,
        LookupUnavailable,
        OperationPending,
        OperationRejected,
        OperationSucceeded,
        OperationUnknown;
export 'src/domain/operation_exception.dart'
    show
        ContradictoryBackendObservationException,
        IllegalOperationTransitionException,
        InvalidBackendObservationException,
        InvalidOperationRecordException,
        OperationIdentityConflictException,
        OperationNotFoundException,
        OperationRecoveryException;
export 'src/domain/operation_identity.dart' show OperationIdentity;
export 'src/domain/operation_record.dart' show OperationRecord;
export 'src/domain/operation_state.dart' show OperationState;
export 'src/domain/recovery_metadata.dart' show RecoveryMetadata;
export 'src/infrastructure/memory_operation_store.dart'
    show MemoryOperationStore;
export 'src/infrastructure/system_clock.dart' show SystemClock;
export 'src/ports/clock.dart' show Clock;
export 'src/ports/operation_handler.dart' show OperationHandler;
export 'src/ports/operation_store.dart' show OperationStore;
export 'src/ports/operation_store_exception.dart'
    show
        OperationStoreConflictException,
        OperationStoreException,
        OperationStoreReadException,
        OperationStoreWriteException,
        StoreCommitStatus;
