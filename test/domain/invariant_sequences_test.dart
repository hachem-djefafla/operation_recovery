import 'dart:math';

import 'package:operation_recovery/operation_recovery.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  // Deterministic seeds are part of each test name and assertion failure.
  for (var seed = 0; seed < 50; seed++) {
    test('generated domain observation sequence seed=$seed', () {
      final random = Random(seed);
      var current = recordIn(OperationState.prepared);
      OperationRecord? firstTerminal;
      for (var step = 0; step < 200; step++) {
        final action = random.nextInt(11);
        final before = current;
        final at = epoch.add(Duration(seconds: step + 10));
        final reason = 'seed=$seed step=$step action=$action';
        try {
          current = switch (action) {
            0 => machine.beginSubmission(current, identity: identity(), at: at),
            1 => machine.applyObservation(
              current,
              OperationSucceeded(
                identity: identity(),
                backendReference: 'tx-987',
              ),
              at: at,
            ),
            2 => machine.applyObservation(
              current,
              OperationRejected(identity: identity(), code: 'declined'),
              at: at,
            ),
            3 => machine.applyObservation(
              current,
              OperationPending(identity: identity()),
              at: at,
            ),
            4 => machine.applyObservation(
              current,
              OperationUnknown(identity: identity()),
              at: at,
            ),
            5 || 6 || 7 => machine.applyObservation(
              current,
              LookupUnavailable(
                identity: identity(),
                reason: LookupFailureReason.values[action - 5],
              ),
              at: at,
            ),
            8 => machine.pause(current, at: at),
            9 => machine.resume(current, at: at),
            _ => restoreRecord(current),
          };
        } on OperationRecoveryException catch (error) {
          expect(
            error,
            anyOf(
              isA<IllegalOperationTransitionException>(),
              isA<ContradictoryBackendObservationException>(),
            ),
            reason: reason,
          );
          expect(current, same(before), reason: reason);
        }

        expect(current.identity, identity(), reason: reason);
        expect(current.createdAt, epoch, reason: reason);
        expect(
          current.version,
          greaterThanOrEqualTo(before.version),
          reason: reason,
        );
        expect(
          current.version,
          lessThanOrEqualTo(before.version + 1),
          reason: reason,
        );
        expect(
          current.updatedAt.isBefore(before.updatedAt),
          isFalse,
          reason: reason,
        );
        if (action >= 3 && action <= 7 && !before.state.isTerminal) {
          expect(current.state.isTerminal, isFalse, reason: reason);
        }
        if (firstTerminal != null) {
          expect(current.state, firstTerminal.state, reason: reason);
          expect(current.version, firstTerminal.version, reason: reason);
          expect(current.updatedAt, firstTerminal.updatedAt, reason: reason);
          expect(
            current.lastObservation,
            same(firstTerminal.lastObservation),
            reason: reason,
          );
        } else if (current.state.isTerminal) {
          firstTerminal = current;
        }
        // Restoration checks structural consistency after each action. This
        // deliberately makes no storage or crash-durability claim.
        expect(() => restoreRecord(current), returnsNormally, reason: reason);
      }
    });
  }
}
