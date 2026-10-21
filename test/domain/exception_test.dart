import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

void main() {
  test('typed exceptions have safe structured descriptions', () {
    final errors = <OperationRecoveryException>[
      const InvalidOperationRecordException('version', 'must be nonnegative'),
      const OperationIdentityConflictException(),
      const IllegalOperationTransitionException(
        state: OperationState.prepared,
        action: 'pause',
      ),
      const InvalidBackendObservationException('code', 'must be nonblank'),
      const ContradictoryBackendObservationException(
        confirmedState: OperationState.succeeded,
        observedState: OperationState.rejected,
      ),
    ];
    for (final error in errors) {
      expect(error, isA<Exception>());
      expect(error.toString(), startsWith(error.runtimeType.toString()));
      expect(error.toString(), isNot(contains('op-123')));
    }
    expect(
      (errors[0] as InvalidOperationRecordException).reason,
      'must be nonnegative',
    );
    expect((errors[2] as IllegalOperationTransitionException).action, 'pause');
    expect(
      (errors[3] as InvalidBackendObservationException).reason,
      'must be nonblank',
    );
  });
}
